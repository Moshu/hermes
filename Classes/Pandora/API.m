//
//  API.m
//  Hermes
//
//  Created by Alex Crichton on 3/15/11.
//  Copyright 2011 Carnegie Mellon University. All rights reserved.
//

#import "API.h"

#include <libxml/xpath.h>
#include <string.h>

typedef struct connection_data {
  SEL selector;
  NSMutableData *data;
  id info;
} connection_data_t;

@implementation API

@synthesize listenerID;

- (id) init {
  activeRequests = [[NSMutableDictionary alloc] init];
  return [super init];
}

/**
 * Gets the current UNIX time
 */
- (int) time {
  return [[NSDate date] timeIntervalSince1970];
}

/**
 * Performs and XPATH query on the specified document, returning the array of
 * contents for each node matched
 */
- (NSArray*) xpath: (xmlDocPtr) doc : (char*) xpath {
  xmlXPathContextPtr xpathCtx;
  xmlXPathObjectPtr xpathObj;

  /* Create xpath evaluation context */
  xpathCtx = xmlXPathNewContext(doc);
  if(xpathCtx == NULL) {
    return nil;
  }

  /* Evaluate xpath expression */
  xpathObj = xmlXPathEvalExpression((xmlChar *)xpath, xpathCtx);
  if(xpathObj == NULL) {
    xmlXPathFreeContext(xpathCtx);
    return nil;
  }

  xmlNodeSetPtr nodes = xpathObj->nodesetval;
  if (!nodes) {
    xmlXPathFreeContext(xpathCtx);
    xmlXPathFreeObject(xpathObj);
    return nil;
  }

  NSMutableArray *resultNodes = [NSMutableArray array];
  char *content;
  for (NSInteger i = 0; i < nodes->nodeNr; i++) {
    if (nodes->nodeTab[i]->children == NULL || nodes->nodeTab[i]->children->content == NULL) {
      content = "";
    } else {
      content = (char*) nodes->nodeTab[i]->children->content;
    }

    NSString *str = [NSString stringWithCString: content encoding:NSUTF8StringEncoding];

    [resultNodes addObject: str];
  }

  /* Cleanup */
  xmlXPathFreeObject(xpathObj);
  xmlXPathFreeContext(xpathCtx);

  return resultNodes;
}

/**
 * Performs and xpath query and returns the content of the first node
 */
- (NSString*) xpathText: (xmlDocPtr)doc : (char*) xpath {
  NSArray  *arr = [self xpath: doc : xpath];
  NSString *ret = nil;

  if (arr != nil && [arr objectAtIndex: 0] != nil) {
    ret = [arr objectAtIndex: 0];
    [ret retain];
  }

  return ret;
}

- (BOOL) sendRequest: (NSString*)method : (NSString*)data : (SEL)callback {
  return [self sendRequest:method : data : callback : nil];
}

/**
 * Sends a request to the server and parses the response as XML
 */
- (BOOL) sendRequest: (NSString*)method : (NSString*)data : (SEL)callback : (id)info{
  NSString *time = [NSString stringWithFormat:@"%d", [self time]];
  NSString *rid  = [time substringFromIndex: 3];
  NSString *url  = [NSString stringWithFormat:
      @"http://www.pandora.com/radio/xmlrpc/v29?rid=%@P&method=%@", rid, method];

  if (![method isEqual: @"sync"] && ![method isEqual: @"authenticateListener"]) {
    NSString *lid = [NSString stringWithFormat:@"lid=%@", listenerID];
    url = [url stringByAppendingString:lid];
  }

  connection_data_t *conn_data = malloc(sizeof(connection_data_t));
  if (conn_data == NULL) {
    return NO;
  }

  // Prepare the request
  NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];

  [request setURL: [NSURL URLWithString:url]];
  [request setHTTPMethod: @"POST"];
  [request addValue: @"application/xml" forHTTPHeaderField: @"Content-Type"];

  // Create the body
  NSMutableData *postBody = [NSMutableData data];
  [postBody appendData: [data dataUsingEncoding:NSUTF8StringEncoding]];
  [request setHTTPBody:postBody];

  // get response asynchronously. Don't start the connection
  // just yet because we need to make sure we put it in the
  // hash table first
  NSURLConnection *conn = [[NSURLConnection alloc]
    initWithRequest:request delegate:self
    startImmediately:NO];

  [request release];

  if (conn == nil) {
    return NO;
  }
  conn_data->selector = callback;
  conn_data->data     = [NSMutableData dataWithCapacity:1024];
  conn_data->info     = info;
  [conn_data->data retain];

  [activeRequests setObject:[NSValue valueWithPointer:conn_data]
    forKey:[NSNumber numberWithInteger: [conn hash]]];

  // Schedule the defaults
  [conn scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  [conn start];

  return YES;
}

- (connection_data_t*) dataForConnection: (NSURLConnection*)connection {
  NSValue *val = [activeRequests objectForKey:
      [NSNumber numberWithInteger:[connection hash]]];
  return [val pointerValue];
}

- (void)cleanupConnection:(NSURLConnection *)connection : (xmlDocPtr)doc {
  connection_data_t *cdata = [self dataForConnection:connection];
  [activeRequests removeObjectForKey:[NSNumber numberWithInteger: [connection hash]]];

  [connection release];
  [cdata->data release]; /* TODO: does this cause errors? */

  SEL selector = cdata->selector;
  id info = cdata->info;
  free(cdata);

  [self performSelector:selector withObject:(id)doc withObject:info];
  xmlFreeDoc(doc);
}

- (void)connection:(NSURLConnection *)connection
    didReceiveData:(NSData *)data {
  connection_data_t *cdata = [self dataForConnection:connection];
  [cdata->data appendData:data];
}

- (void)connection:(NSURLConnection *)connection
    didReceiveResponse:(NSHTTPURLResponse *)response {
  if ([response statusCode] < 200 || [response statusCode] >= 300) {
    [connection cancel];
    [self cleanupConnection:connection : NULL];
  }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
  [self cleanupConnection:connection : NULL];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
  connection_data_t *cdata = [self dataForConnection:connection];

  xmlDocPtr doc = xmlReadMemory([cdata->data bytes], [cdata->data length], "",
                                NULL, XML_PARSE_RECOVER);

  NSArray *fault = [self xpath: doc : "//methodResponse/fault"];

  if ([fault count] > 0) {
    NSString *resp = [[NSString alloc] initWithData:cdata->data
                                           encoding:NSASCIIStringEncoding];
    NSLog(@"Fault!: %@", resp);
    [resp release];
    xmlFreeDoc(doc);
    [self cleanupConnection:connection : NULL];

    return;
  }

  [self cleanupConnection:connection : doc];
}

@end

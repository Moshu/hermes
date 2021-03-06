#import <AudioStreamer/AudioStreamer.h>

#import "HermesAppDelegate.h"
#import "Pandora/Station.h"
#import "PreferencesController.h"
#import "StationsController.h"

@implementation Station

@synthesize stationId, name, playing, token, shared, allowAddMusic, allowRename;

- (id) init {
  songs = [NSMutableArray arrayWithCapacity:10];

  return self;
}

- (id) initWithCoder:(NSCoder *)aDecoder {
  if ((self = [self init])) {
    [self setStationId:[aDecoder decodeObjectForKey:@"stationId"]];
    [self setName:[aDecoder decodeObjectForKey:@"name"]];
    [self setPlaying:[aDecoder decodeObjectForKey:@"playing"]];
    [self setVolume:[aDecoder decodeFloatForKey:@"volume"]];
    [self setCreated:[aDecoder decodeInt32ForKey:@"created"]];
    [self setToken:[aDecoder decodeObjectForKey:@"token"]];
    [self setShared:[aDecoder decodeBoolForKey:@"shared"]];
    [self setAllowAddMusic:[aDecoder decodeBoolForKey:@"allowAddMusic"]];
    [self setAllowRename:[aDecoder decodeBoolForKey:@"allowRename"]];
    lastKnownSeekTime = [aDecoder decodeFloatForKey:@"lastKnownSeekTime"];
    [songs addObjectsFromArray:[aDecoder decodeObjectForKey:@"songs"]];
    for (Song *s in songs) {
      [s setStation:self];
    }
  }
  return self;
}

- (void) encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:stationId forKey:@"stationId"];
  [aCoder encodeObject:name forKey:@"name"];
  [aCoder encodeObject:playing forKey:@"playing"];
  double seek = -1;
  if (playing) {
    [stream progress:&seek];
  }
  [aCoder encodeFloat:seek forKey:@"lastKnownSeekTime"];
  [aCoder encodeFloat:volume forKey:@"volume"];
  [aCoder encodeInt32:_created forKey:@"created"];
  [aCoder encodeObject:songs forKey:@"songs"];
  [aCoder encodeObject:token forKey:@"token"];
  [aCoder encodeBool:shared forKey:@"shared"];
  [aCoder encodeBool:allowAddMusic forKey:@"allowAddMusic"];
  [aCoder encodeBool:allowRename forKey:@"allowRename"];
}

- (void) dealloc {
  [self stop];
}

- (BOOL) isEqual:(id)object {
  return [stationId isEqual:[object stationId]];
}

- (void) setRadio:(Pandora *)pandora {
  if (radio != nil) {
    [[NSNotificationCenter defaultCenter]
     removeObserver:self
     name:nil
     object:radio];
  }
  radio = pandora;

  NSString *n = [NSString stringWithFormat:@"hermes.fragment-fetched.%@",
      token];

  [[NSNotificationCenter defaultCenter]
    addObserver:self
    selector:@selector(songsLoaded:)
    name:n
    object:pandora];
}

- (void) songsLoaded: (NSNotification*)not {
  NSArray *more = [not userInfo][@"songs"];

  if (more != nil) {
    [songs addObjectsFromArray: more];
  }

  if (shouldPlaySongOnFetch) {
    shouldPlaySongOnFetch = NO;
    [self play];
  }

  [[NSNotificationCenter defaultCenter]
    postNotificationName:@"songs.loaded" object:self];
}

- (void) clearSongList {
  [songs removeAllObjects];
}

- (void) fetchMoreSongs {
  [radio getFragment: self];
}

- (void) fetchSongsIfNecessary {
  if ([songs count] <= 1) {
    [self fetchMoreSongs];
  }
}

- (void) setAudioStream {
  if (stream != nil) {
    [[NSNotificationCenter defaultCenter]
        removeObserver:self
                  name:nil
                object:stream];
  }
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSURL *url;

  switch ([defaults integerForKey:DESIRED_QUALITY]) {
    case QUALITY_HIGH:
      NSLogd(@"quality high");
      url = [NSURL URLWithString:[playing highUrl]];
      break;
    case QUALITY_LOW:
      NSLogd(@"quality low");
      url = [NSURL URLWithString:[playing lowUrl]];
      break;

    case QUALITY_MED:
    default:
      NSLogd(@"quality med");
      url = [NSURL URLWithString:[playing medUrl]];
      break;
  }
  assert(url != nil);
  [stream stop];
  NSLogd(@"Creating with %@", url);
  stream = [AudioStreamer streamWithURL: url];
  [stream setBufferInfinite:TRUE];
  [stream setTimeoutInterval:15];
  if (PREF_KEY_VALUE(PROXY_AUDIO)) {
    switch ([PREF_KEY_VALUE(ENABLED_PROXY) intValue]) {
      case PROXY_HTTP:
        [stream setHTTPProxy:PREF_KEY_VALUE(PROXY_HTTP_HOST)
                        port:[PREF_KEY_VALUE(PROXY_HTTP_PORT) intValue]];
        break;
      case PROXY_SOCKS:
        [stream setSOCKSProxy:PREF_KEY_VALUE(PROXY_SOCKS_HOST)
                         port:[PREF_KEY_VALUE(PROXY_SOCKS_PORT) intValue]];
        break;
      default:
        break;
    }
  }
  volumeSet = [stream setVolume:volume];

  /* Watch for error notifications */
  [[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(playbackStateChanged:)
           name:ASStatusChangedNotification
         object:stream];
  [[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(bitrateReady:)
           name:ASBitrateReadyNotification
         object:stream];
}

- (void)bitrateReady: (NSNotification*)notification {
  if ([notification object] != stream) return;
  if (lastKnownSeekTime == 0)
    return;
  NSLogd(@"attempting seek to: %g", lastKnownSeekTime);
  if (![stream seekToTime:lastKnownSeekTime])
    return;
  retrying = NO;
  lastKnownSeekTime = 0;
}

- (void)playbackStateChanged: (NSNotification *)aNotification {
  if ([aNotification object] != stream) return;
  if (!volumeSet) {
    volumeSet = [stream setVolume:volume];
  }

  int code = [stream errorCode];
  if (code != 0) {
    /* If we've hit an error, then we want to record out current progress into
       the song. Only do this if we're not in the process of retrying to
       establish a connection, so that way we don't blow away the original
       progress from when the error first happened */
    if (!retrying) {
      if (![stream progress:&lastKnownSeekTime]) {
        lastKnownSeekTime = 0;
      }
    }

    /* If the network connection just outright failed, then we shouldn't be
       retrying with a new auth token because it will never work for that
       reason. Most likely this is some network trouble and we should have the
       opportunity to hit a button to retry this specific connection so we can
       at least hope to regain our current place in the song */
    if (code == AS_NETWORK_CONNECTION_FAILED || code == AS_TIMED_OUT) {
      NSLogd(@"network error: %@", [stream networkError]);
      [[NSNotificationCenter defaultCenter]
        postNotificationName:@"hermes.stream-error" object:self];

    /* Otherwise, this might be because our authentication token is invalid, but
       just in case, retry the current song automatically a few times before we
       finally give up and clear our cache of songs (see below) */
    } else {
      NSLogd(@"Error on playback stream! count:%lu, Retrying...", tries);
      NSLogd(@"error: %@", [AudioStreamer stringForErrorCode:code]);
      [self retry:YES];
    }

  /* When the stream has finished, move on to the next song */
  } else if ([stream isDone]) {
    NSLogd(@"is stopped now");
    if (!nexting) [self next];
  }
}

- (void) retry:(BOOL)countTries {
  if (countTries) {
    if (tries > 2) {
      NSLogd(@"Retried too many times, just nexting...");
      /* If we retried a bunch and it didn't work, the most likely cause is that
         the listed URL for the song has since expired. This probably also means
         that anything else in the queue (fetched at the same time) is also
         invalid, so empty the entire thing and have next fetch some more */
      [songs removeAllObjects];
      [self next];
      return;
    }
    tries++;
  }

  retrying = YES;

  [self setAudioStream];
  [stream start];
}

- (void) retryWithCount {
  [self retry:YES];
}

- (void) play {
  NSLogd(@"Playing %@", name);
  if (stream) {
    [stream play];
    return;
  }

  if ([songs count] == 0) {
    NSLogd(@"no songs, fetching some more");
    shouldPlaySongOnFetch = YES;
    [self fetchMoreSongs];
    return;
  }

  playing = songs[0];
  [songs removeObjectAtIndex:0];

  [self setAudioStream];
  tries = 0;
  [stream start];

  [[NSNotificationCenter defaultCenter]
    postNotificationName:@"song.playing" object:self];

  [self fetchSongsIfNecessary];
}

- (void) pause {
  if (stream != nil) {
    [stream pause];
  }
}

- (BOOL) isPaused {
  return stream != nil && [stream isPaused];
}

- (BOOL) isPlaying {
  return stream != nil && [stream isPlaying];
}

- (BOOL) isIdle {
  return stream != nil && [stream isDone];
}

- (BOOL) isError {
  return stream != nil && [stream errorCode] != AS_NO_ERROR;
}

- (BOOL) progress:(double*)ret {
  return [stream progress:ret];
}

- (BOOL) duration:(double*)ret {
  return [stream duration:ret];
}

- (void) next {
  if (nexting) return;
  nexting = YES;
  lastKnownSeekTime = 0;
  retrying = FALSE;
  [self stop];
  [self play];
  nexting = NO;
}

- (void) stop {
  nexting = YES;
  [stream stop];
  if (stream != nil) {
    [[NSNotificationCenter defaultCenter]
        removeObserver:self
                  name:nil
                object:stream];
  }
  stream = nil;
  playing = nil;
}

- (NSString*) streamNetworkError {
  if ([stream errorCode] == AS_NETWORK_CONNECTION_FAILED) {
    return [[stream networkError] localizedDescription];
  }
  return [AudioStreamer stringForErrorCode:[stream errorCode]];
}

- (void) setVolume:(double)vol {
  volumeSet = [stream setVolume:vol];
  self->volume = vol;
}

- (void) copyFrom: (Station*) other {
  [songs removeAllObjects];
  /* Add the previously playing song to the front of the queue if
     there was one */
  if ([other playing] != nil) {
    [songs addObject:[other playing]];
  }
  [songs addObjectsFromArray:other->songs];
  lastKnownSeekTime = other->lastKnownSeekTime;
  volume = other->volume;
  if (lastKnownSeekTime > 0) {
    retrying = YES;
  }
}

- (NSScriptObjectSpecifier *) objectSpecifier {
  HermesAppDelegate *delegate = [NSApp delegate];
  StationsController *stationsc = [delegate stations];
  int index = [stationsc stationIndex:self];

  NSScriptClassDescription *containerClassDesc =
      [NSScriptClassDescription classDescriptionForClass:[NSApp class]];

  return [[NSIndexSpecifier alloc]
           initWithContainerClassDescription:containerClassDesc
           containerSpecifier:nil key:@"stations" index:index];
}

@end

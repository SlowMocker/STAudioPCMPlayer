//
//  STAudioPCMPlayer.m
//  Local4CHAudioPlayer
//
//  Created by 赵鑫磊 on 16/3/28.
//  Copyright © 2016年 赵鑫磊. All rights reserved.
//

#import "STAudioPCMPlayer.h"
#define kSampleRate 48000

NSString * const STAudioPCMPlayerStateDidChangeNotification = @"STAudioPCMPlayerStateDidChangeNotification";

@interface STAudioPCMPlayer () {
    
}

void AudioPlayerAQInputCallback(void *input, AudioQueueRef outQ, AudioQueueBufferRef outQB);

@property (nonatomic, strong) NSLock *synlock; // 同步锁
@property (nonatomic, assign) AudioQueueRef audioQueue;//音频播放队列
@property (nonatomic, assign) AudioQueueBufferRef *audioQueueBuffers;

@property (nonatomic, assign) STAudioPCMPlayerState playerState;

@property (nonatomic, assign) BOOL isAudioSetup;



@end

@implementation STAudioPCMPlayer
@synthesize audioQueueBuffers = _audioQueueBuffers;

#pragma mark --- Custom Setter/Getter
- (AudioQueueBufferRef *)audioQueueBuffers {
    if (!_audioQueueBuffers) {
        _audioQueueBuffers = new AudioQueueBufferRef[kQueueBufferCount];
    }
    return _audioQueueBuffers;
}


- (void)setAudioQueueBuffers:(AudioQueueBufferRef *)audioQueueBuffers {
    if (_audioQueueBuffers != audioQueueBuffers) {
        if (_audioQueueBuffers) {
            delete [] _audioQueueBuffers;
        }
        _audioQueueBuffers = audioQueueBuffers;
    }
}


- (STAudioPCMPlayerState)currentState {
    return self.playerState;
}

- (void)setPlayerState:(STAudioPCMPlayerState)playerState {
    if (_playerState != playerState) {
        _playerState = playerState;
        [[NSNotificationCenter defaultCenter] postNotificationName:STAudioPCMPlayerStateDidChangeNotification object:self userInfo:nil];
    }
}


+ (AudioStreamBasicDescription)defaultAudioDescriptionWithSampleRate:(Float64)sampleRate {
    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mChannelsPerFrame = 2;///双声道
    asbd.mFramesPerPacket = 1;//每一个packet一侦数据
    asbd.mBitsPerChannel = 16;//每个采样点16bit量化
    asbd.mBytesPerFrame = (asbd.mBitsPerChannel/8) * asbd.mChannelsPerFrame;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mFramesPerPacket;
    
    return asbd;
}




- (void) dealloc {

    [self freeAudioBuffers];
    self.audioQueueBuffers = NULL;
    NSLog(@"PCMPlayer Dealloc");
}


#define kReadInBufferSize (1024*4)
- (instancetype)initWithSampleRate:(NSInteger)sampleRate {
    self = [super init];
    if (self) {
        _synlock = [[NSLock alloc] init];
        _sampleRate = sampleRate;
        _audioDescription = [STAudioPCMPlayer defaultAudioDescriptionWithSampleRate:sampleRate];
    }
    return self;
}

- (instancetype)init {
    return [self initWithSampleRate:kSampleRate];
}


#pragma mark --- Audio Play Contorl
- (void)setupAudioOutput {
    if (!self.isAudioSetup) {
        NSError *error = nil;
        [[AVAudioSession sharedInstance]setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
        [[AVAudioSession sharedInstance] setPreferredSampleRate:self.sampleRate error:&error];
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        if (error) {
            NSLog(@"AVAudioSession Error: %@", error.localizedDescription);
        }
        [self audioNewOutput];
        [self allocAudioBuffers];
        self.isAudioSetup = YES;
    }
}

- (void)prepareToPlay {
    if (!self.isAudioSetup) {
        [self setupAudioOutput];
    }
    for(int i=0; i<kQueueBufferCount; i++)
    {
        [self readPCMAndPlay:_audioQueue buffer:self.audioQueueBuffers[i]];
    }
    self.playerState = STAudioPCMPlayerStatePrepare;
}


- (void)play {
    if (self.isAudioSetup) {
        AudioQueueStart(_audioQueue, NULL);
        self.playerState = STAudioPCMPlayerStatePlaying;
    }
}


- (void)pause {
    if (self.isAudioSetup) {
        AudioQueuePause(_audioQueue);
        self.playerState = STAudioPCMPlayerStatePause;
    }
}

- (void)stop {
    if (self.isAudioSetup) {
        AudioQueueStop(_audioQueue, true);
        self.playerState = STAudioPCMPlayerStateIdle;
    }
}


#pragma mark --- Setup Audio Buffer
// TODO: Alloc Audio Buffer
- (void)allocAudioBuffers {
    // 添加buffer区
    for(int i=0; i<kQueueBufferCount; i++) {
        int result =  AudioQueueAllocateBuffer(_audioQueue, kMinSizePerBuffer, &self.audioQueueBuffers[i]); //创建buffer区，kMinSizePerBuffer为每一侦所需要的最小的大小，该大小应该比每次往buffer里写的最大的一次还大
        NSLog(@"AudioQueueAllocateBuffer i = %d,result = %d", i, result);
    }
}

// TODO: Free Audio Buffer
- (void)freeAudioBuffers {
    for(int i=0; i<kQueueBufferCount; i++) {
        int result =  AudioQueueFreeBuffer(_audioQueue, self.audioQueueBuffers[i]);

        NSLog(@"AudioQueueFreeBuffer i = %d,result = %d", i, result);
    }
}
// TODO: Create Audio Output
- (void)audioNewOutput {
    /// 创建一个新的从audioqueue到硬件层的通道
    //  AudioQueueNewOutput(&audioDescription, AudioPlayerAQInputCallback, self, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &audioQueue);///使用当前线程播
    AudioQueueNewOutput(&_audioDescription, AudioPlayerAQInputCallback, (__bridge void * _Nullable)(self), nil, nil, 0, &_audioQueue);
}



// Audio Queue Buffer Callback
- (void)readPCMAndPlay:(AudioQueueRef)outQ buffer:(AudioQueueBufferRef)outQB {
    [self.synlock lock];
    
    if (_dataSource && [_dataSource respondsToSelector:@selector(audioPCMPlayer:hasBytesWithLength:)]) {
        
        UInt32 readLength = 0;
        Byte *readInByte = [_dataSource audioPCMPlayer:self hasBytesWithLength:&readLength];
        
        if (readLength > 0 && !!readInByte) {
            outQB->mAudioDataByteSize = readLength;
            Byte *audioData = (Byte *)outQB->mAudioData;
            memcpy(audioData, readInByte, readLength);
            AudioQueueEnqueueBuffer(outQ, outQB, 0, NULL);
            
            self.playerState = STAudioPCMPlayerStatePlaying;
        } else {
            self.playerState = STAudioPCMPlayerStateError;
        }
        
    } else {
        NSLog(@"DataSource is not SET");
    }
    
    NSLog(@"Current Thread: %@", [NSThread currentThread]);
    [self.synlock unlock];
}

- (void)checkUsedQueueBuffer:(AudioQueueBufferRef) qbuf {
    for (int i = 0; i < kQueueBufferCount; i++) {
        if (qbuf == self.audioQueueBuffers[i]) {
            NSLog(@"AudioPlayerAQInputCallback,bufferindex = %d", i);
            break;
        }
    }
}

void AudioPlayerAQInputCallback(void *input, AudioQueueRef outQ, AudioQueueBufferRef outQB) {
    NSLog(@"AQInputCallback");
    STAudioPCMPlayer *pcmPlayer = (__bridge STAudioPCMPlayer *)input;
    [pcmPlayer checkUsedQueueBuffer:outQB];
    [pcmPlayer readPCMAndPlay:outQ buffer:outQB];
}


@end

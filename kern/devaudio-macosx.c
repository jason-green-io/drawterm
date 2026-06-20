#include <AudioToolbox/AudioServices.h>
#include <AudioToolbox/AudioQueue.h>
#include <pthread.h>
#include <time.h>

#include	"u.h"
#include	"lib.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"devaudio.h"

/* kAudioObjectPropertyElementMain replaced kAudioObjectPropertyElementMaster in macOS 12 */
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#define	THRESHOLD		0.005
#define	NUM_CHANNELS		2
#define	SAMPLE_RATE		44100
#define	FRAMES_PER_BUFFER	2048
#define	SAMPLE_SILENCE		0
#define	SAMPLE_SIZE		2
#define	RING_BUFFER_SECONDS	2
#define	NUM_AQ_BUFFERS		4

static AudioQueueRef inputQueue = NULL;
static AudioQueueRef outputQueue = NULL;
static AudioQueueBufferRef inputBuffers[NUM_AQ_BUFFERS];
static AudioQueueBufferRef outputBuffers[NUM_AQ_BUFFERS];
static int inputChannels, outputChannels;
static int inputFrameSize, outputFrameSize;
static int leftvol, rightvol;
static int inputStreamActive = 0;
static int outputStreamActive = 0;

static pthread_mutex_t inputReadyMu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t inputReadyCond = PTHREAD_COND_INITIALIZER;

static pthread_mutex_t outputSpaceMu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t outputSpaceCond = PTHREAD_COND_INITIALIZER;

typedef struct RingBuffer {
	uchar	*data;
	int	size;
	int	writePos;
	int	readPos;
	int	available;
	pthread_mutex_t	lock;
	int	running;
} RingBuffer;

static RingBuffer *ringBuf = NULL;
static RingBuffer *playbackRingBuf = NULL;

static float
normalize(float oldval)
{
	float newmin = 0.01, newmax = 1.0;
	float oldmin = 1.0, oldmax = 100.0;
	return (((oldval - oldmin) * (newmax - newmin)) / (oldmax - oldmin)) + newmin;
}

static float
denormalize(float oldval)
{
	float oldmin = 0.01, oldmax = 1.0;
	float newmin = 1.0, newmax = 100.0;
	return (((oldval - oldmin) * (newmax - newmin)) / (oldmax - oldmin)) + newmin;
}

static AudioDeviceID	obtainDefaultOutputDevice(void);
static float		systemVolume(void);
static void		setSystemVolume(float);

static void
ringBufWrite(RingBuffer *rb, uchar *data, int nbytes)
{
	int chunk;

	pthread_mutex_lock(&rb->lock);
	while(nbytes > 0){
		chunk = rb->size - rb->writePos;
		if(chunk > nbytes)
			chunk = nbytes;
		memmove(rb->data + rb->writePos, data, chunk);
		rb->writePos = (rb->writePos + chunk) % rb->size;
		rb->available += chunk;
		if(rb->available > rb->size){
			int overflow = rb->available - rb->size;
			rb->readPos = (rb->readPos + overflow) % rb->size;
			rb->available = rb->size;
		}
		data += chunk;
		nbytes -= chunk;
	}
	pthread_mutex_unlock(&rb->lock);
}

static int
ringBufRead(RingBuffer *rb, uchar *data, int nbytes)
{
	int chunk, totalRead;

	pthread_mutex_lock(&rb->lock);
	if(nbytes > rb->available)
		nbytes = rb->available;
	totalRead = nbytes;
	while(nbytes > 0){
		chunk = rb->size - rb->readPos;
		if(chunk > nbytes)
			chunk = nbytes;
		memmove(data, rb->data + rb->readPos, chunk);
		rb->readPos = (rb->readPos + chunk) % rb->size;
		rb->available -= chunk;
		data += chunk;
		nbytes -= chunk;
	}
	pthread_mutex_unlock(&rb->lock);
	return totalRead;
}

static void
audioQueueInputCallback(void *userData, AudioQueueRef queue,
	AudioQueueBufferRef buffer,
	const AudioTimeStamp *startTime,
	UInt32 numPackets,
	const AudioStreamPacketDescription *packetDescs)
{
	uchar *stereoBuffer;
	short *src, *dst;
	int numFrames, i;

	if(!ringBuf || !ringBuf->running)
		return;

	numFrames = buffer->mAudioDataByteSize / inputFrameSize;

	if(inputChannels == 1 && outputChannels == 2){
		stereoBuffer = malloc(numFrames * outputFrameSize);
		if(stereoBuffer != NULL){
			src = (short*)buffer->mAudioData;
			dst = (short*)stereoBuffer;
			for(i = 0; i < numFrames; i++){
				dst[i*2] = src[i];
				dst[i*2 + 1] = src[i];
			}
			ringBufWrite(ringBuf, stereoBuffer, numFrames * outputFrameSize);
			free(stereoBuffer);
		}
	} else {
		ringBufWrite(ringBuf, buffer->mAudioData, buffer->mAudioDataByteSize);
	}
	pthread_mutex_lock(&inputReadyMu);
	pthread_cond_signal(&inputReadyCond);
	pthread_mutex_unlock(&inputReadyMu);
	AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static void
audioQueueOutputCallback(void *userData, AudioQueueRef queue,
	AudioQueueBufferRef buffer)
{
	int bytesRead;

	if(!playbackRingBuf || !playbackRingBuf->running){
		memset(buffer->mAudioData, SAMPLE_SILENCE, buffer->mAudioDataBytesCapacity);
		buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
		AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
		return;
	}

	bytesRead = ringBufRead(playbackRingBuf, buffer->mAudioData, buffer->mAudioDataBytesCapacity);
	if(bytesRead > 0){
		buffer->mAudioDataByteSize = bytesRead;
	} else {
		memset(buffer->mAudioData, SAMPLE_SILENCE, buffer->mAudioDataBytesCapacity);
		buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
	}
	pthread_mutex_lock(&outputSpaceMu);
	pthread_cond_signal(&outputSpaceCond);
	pthread_mutex_unlock(&outputSpaceMu);
	AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static void
startInputStream(void)
{
	char errbuf[ERRMAX];
	AudioStreamBasicDescription format;
	OSStatus status;
	int i, bufferSize;

	if(inputStreamActive)
		return;

	ringBuf = malloc(sizeof(RingBuffer));
	if(ringBuf == NULL)
		error("failed to allocate ring buffer");

	ringBuf->size = RING_BUFFER_SECONDS * SAMPLE_RATE * outputFrameSize;
	ringBuf->data = malloc(ringBuf->size);
	if(ringBuf->data == NULL){
		free(ringBuf);
		ringBuf = NULL;
		error("failed to allocate ring buffer data");
	}
	ringBuf->writePos = 0;
	ringBuf->readPos = 0;
	ringBuf->available = 0;
	ringBuf->running = 1;

	if(pthread_mutex_init(&ringBuf->lock, NULL) != 0){
		free(ringBuf->data);
		free(ringBuf);
		ringBuf = NULL;
		error("failed to initialize mutex");
	}

	format.mSampleRate = SAMPLE_RATE;
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
	format.mBytesPerPacket = inputFrameSize;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = inputFrameSize;
	format.mChannelsPerFrame = inputChannels;
	format.mBitsPerChannel = 16;

	status = AudioQueueNewInput(&format, audioQueueInputCallback, NULL, NULL, NULL, 0, &inputQueue);
	if(status != noErr){
		pthread_mutex_destroy(&ringBuf->lock);
		free(ringBuf->data);
		free(ringBuf);
		ringBuf = NULL;
		snprint(errbuf, sizeof(errbuf), "AudioQueueNewInput failed: %d (check microphone permission)", (int)status);
		error(errbuf);
	}

	bufferSize = FRAMES_PER_BUFFER * inputFrameSize;
	for(i = 0; i < NUM_AQ_BUFFERS; i++){
		status = AudioQueueAllocateBuffer(inputQueue, bufferSize, &inputBuffers[i]);
		if(status != noErr){
			AudioQueueDispose(inputQueue, true);
			inputQueue = NULL;
			pthread_mutex_destroy(&ringBuf->lock);
			free(ringBuf->data);
			free(ringBuf);
			ringBuf = NULL;
			snprint(errbuf, sizeof(errbuf), "AudioQueueAllocateBuffer failed: %d", (int)status);
			error(errbuf);
		}
		AudioQueueEnqueueBuffer(inputQueue, inputBuffers[i], 0, NULL);
	}

	status = AudioQueueStart(inputQueue, NULL);
	if(status != noErr){
		AudioQueueDispose(inputQueue, true);
		inputQueue = NULL;
		pthread_mutex_destroy(&ringBuf->lock);
		free(ringBuf->data);
		free(ringBuf);
		ringBuf = NULL;
		snprint(errbuf, sizeof(errbuf), "AudioQueueStart failed: %d", (int)status);
		error(errbuf);
	}
	inputStreamActive = 1;
}

static void
startOutputStream(void)
{
	char errbuf[ERRMAX];
	int ringBufferSize;
	AudioStreamBasicDescription format;
	OSStatus status;
	int i, bufferSize;

	if(outputStreamActive)
		return;

	ringBufferSize = RING_BUFFER_SECONDS * SAMPLE_RATE * outputFrameSize;
	playbackRingBuf = malloc(sizeof(RingBuffer));
	if(playbackRingBuf == NULL)
		error("failed to allocate playback ring buffer");

	playbackRingBuf->data = malloc(ringBufferSize);
	if(playbackRingBuf->data == NULL){
		free(playbackRingBuf);
		playbackRingBuf = NULL;
		error("failed to allocate playback ring buffer data");
	}
	playbackRingBuf->size = ringBufferSize;
	playbackRingBuf->writePos = 0;
	playbackRingBuf->readPos = 0;
	playbackRingBuf->available = 0;
	playbackRingBuf->running = 1;

	if(pthread_mutex_init(&playbackRingBuf->lock, NULL) != 0){
		free(playbackRingBuf->data);
		free(playbackRingBuf);
		playbackRingBuf = NULL;
		error("failed to initialize mutex");
	}

	format.mSampleRate = SAMPLE_RATE;
	format.mFormatID = kAudioFormatLinearPCM;
	format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
	format.mBytesPerPacket = outputFrameSize;
	format.mFramesPerPacket = 1;
	format.mBytesPerFrame = outputFrameSize;
	format.mChannelsPerFrame = outputChannels;
	format.mBitsPerChannel = 16;

	status = AudioQueueNewOutput(&format, audioQueueOutputCallback, NULL, NULL, NULL, 0, &outputQueue);
	if(status != noErr){
		pthread_mutex_destroy(&playbackRingBuf->lock);
		free(playbackRingBuf->data);
		free(playbackRingBuf);
		playbackRingBuf = NULL;
		snprint(errbuf, sizeof(errbuf), "AudioQueueNewOutput failed: %d", (int)status);
		error(errbuf);
	}

	bufferSize = FRAMES_PER_BUFFER * outputFrameSize;
	for(i = 0; i < NUM_AQ_BUFFERS; i++){
		status = AudioQueueAllocateBuffer(outputQueue, bufferSize, &outputBuffers[i]);
		if(status != noErr){
			AudioQueueDispose(outputQueue, true);
			outputQueue = NULL;
			pthread_mutex_destroy(&playbackRingBuf->lock);
			free(playbackRingBuf->data);
			free(playbackRingBuf);
			playbackRingBuf = NULL;
			snprint(errbuf, sizeof(errbuf), "AudioQueueAllocateBuffer failed: %d", (int)status);
			error(errbuf);
		}
		memset(outputBuffers[i]->mAudioData, SAMPLE_SILENCE, bufferSize);
		outputBuffers[i]->mAudioDataByteSize = bufferSize;
		AudioQueueEnqueueBuffer(outputQueue, outputBuffers[i], 0, NULL);
	}

	status = AudioQueueStart(outputQueue, NULL);
	if(status != noErr){
		AudioQueueDispose(outputQueue, true);
		outputQueue = NULL;
		pthread_mutex_destroy(&playbackRingBuf->lock);
		free(playbackRingBuf->data);
		free(playbackRingBuf);
		playbackRingBuf = NULL;
		snprint(errbuf, sizeof(errbuf), "AudioQueueStart failed: %d", (int)status);
		error(errbuf);
	}
	outputStreamActive = 1;
}

void
audiodevopen(void)
{
	inputChannels = 1;
	outputChannels = NUM_CHANNELS;
	inputFrameSize = inputChannels * SAMPLE_SIZE;
	outputFrameSize = outputChannels * SAMPLE_SIZE;
	leftvol = rightvol = (int)denormalize(systemVolume());
	/* streams started lazily on first read/write */
}

void
audiodevclose(void)
{
	if(inputStreamActive && inputQueue != NULL){
		if(ringBuf != NULL)
			ringBuf->running = 0;
		pthread_mutex_lock(&inputReadyMu);
		pthread_cond_broadcast(&inputReadyCond);
		pthread_mutex_unlock(&inputReadyMu);
		AudioQueueStop(inputQueue, true);
		AudioQueueDispose(inputQueue, true);
		inputQueue = NULL;
		inputStreamActive = 0;
		if(ringBuf != NULL){
			pthread_mutex_destroy(&ringBuf->lock);
			free(ringBuf->data);
			free(ringBuf);
			ringBuf = NULL;
		}
	}
	if(outputStreamActive && outputQueue != NULL){
		if(playbackRingBuf != NULL)
			playbackRingBuf->running = 0;
		pthread_mutex_lock(&outputSpaceMu);
		pthread_cond_broadcast(&outputSpaceCond);
		pthread_mutex_unlock(&outputSpaceMu);
		AudioQueueStop(outputQueue, true);
		AudioQueueDispose(outputQueue, true);
		outputQueue = NULL;
		outputStreamActive = 0;
		if(playbackRingBuf != NULL){
			pthread_mutex_destroy(&playbackRingBuf->lock);
			free(playbackRingBuf->data);
			free(playbackRingBuf);
			playbackRingBuf = NULL;
		}
	}
}

int
audiodevread(void *v, int n)
{
	int bytesRead;
	struct timespec ts;

	startInputStream();
	if(ringBuf == NULL)
		return 0;

	n = (n / outputFrameSize) * outputFrameSize;

	/*
	 * Return as soon as any data is available — don't try to fill n bytes.
	 * Each call returns one callback's worth (~46ms); Plan 9 loops for more.
	 * Short timeout (50ms) bounds the cond signal race.
	 */
	while(ringBuf->running){
		bytesRead = ringBufRead(ringBuf, v, n);
		if(bytesRead > 0)
			return bytesRead;
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += 50000000; /* 50ms */
		if(ts.tv_nsec >= 1000000000){
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000;
		}
		pthread_mutex_lock(&inputReadyMu);
		pthread_cond_timedwait(&inputReadyCond, &inputReadyMu, &ts);
		pthread_mutex_unlock(&inputReadyMu);
	}
	return ringBufRead(ringBuf, v, n);
}

int
audiodevwrite(void *v, int n)
{
	int bytesToWrite;
	int available;
	struct timespec ts;

	startOutputStream();
	if(playbackRingBuf == NULL)
		return 0;
	bytesToWrite = (n / outputFrameSize) * outputFrameSize;
	if(bytesToWrite <= 0)
		return 0;

	/* Block until ring buffer has room to avoid flooding ahead of playback */
	while(playbackRingBuf->running){
		pthread_mutex_lock(&playbackRingBuf->lock);
		available = playbackRingBuf->available;
		pthread_mutex_unlock(&playbackRingBuf->lock);
		if(available + bytesToWrite <= playbackRingBuf->size / 2)
			break;
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += 10000000; /* 10ms */
		if(ts.tv_nsec >= 1000000000){
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000;
		}
		pthread_mutex_lock(&outputSpaceMu);
		pthread_cond_timedwait(&outputSpaceCond, &outputSpaceMu, &ts);
		pthread_mutex_unlock(&outputSpaceMu);
	}

	ringBufWrite(playbackRingBuf, v, bytesToWrite);
	return bytesToWrite;
}

void
audiodevsetvol(int what, int left, int right)
{
	if(what == Vaudio){
		leftvol = left;
		rightvol = right;
		setSystemVolume(normalize((float)left));
	}
}

void
audiodevgetvol(int what, int *left, int *right)
{
	switch(what){
	case Vspeed:
		*left = *right = SAMPLE_RATE;
		break;
	case Vaudio:
		leftvol = rightvol = (int)denormalize(systemVolume());
		*left = *right = rightvol;
		break;
	case Vtreb:
	case Vbass:
		*left = *right = 50;
		break;
	case Vpcm:
		*left = *right = 16;
		break;
	default:
		*left = *right = 0;
	}
}

static AudioDeviceID
obtainDefaultOutputDevice(void)
{
	AudioDeviceID theAnswer = kAudioObjectUnknown;
	UInt32 theSize = sizeof(AudioDeviceID);
	AudioObjectPropertyAddress theAddress;

	theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
	theAddress.mScope = kAudioObjectPropertyScopeGlobal;
	theAddress.mElement = kAudioObjectPropertyElementMain;

	if(!AudioObjectHasProperty(kAudioObjectSystemObject, &theAddress))
		return theAnswer;
	AudioObjectGetPropertyData(kAudioObjectSystemObject, &theAddress, 0, NULL, &theSize, &theAnswer);
	return theAnswer;
}

static float
systemVolume(void)
{
	AudioDeviceID defaultDevID;
	UInt32 theSize = sizeof(Float32);
	OSStatus theError;
	Float32 theVolume = 0;
	AudioObjectPropertyAddress theAddress;

	defaultDevID = obtainDefaultOutputDevice();
	if(defaultDevID == kAudioObjectUnknown)
		return 0.0;

	theAddress.mSelector = kAudioDevicePropertyVolumeScalar;
	theAddress.mScope = kAudioDevicePropertyScopeOutput;
	theAddress.mElement = 1; /* master/main channel */

	if(!AudioObjectHasProperty(defaultDevID, &theAddress))
		return 0.0;

	theError = AudioObjectGetPropertyData(defaultDevID, &theAddress, 0, NULL, &theSize, &theVolume);
	if(theError != noErr)
		return 0.0;

	theVolume = theVolume > 1.0 ? 1.0 : (theVolume < 0.0 ? 0.0 : theVolume);
	return theVolume;
}

static void
setSystemVolume(float theVolume)
{
	AudioObjectPropertyAddress theAddress;
	AudioDeviceID defaultDevID;
	OSStatus theError;
	UInt32 muted;
	Boolean canSetVol, canMute, hasMute;
	float newValue;

	defaultDevID = obtainDefaultOutputDevice();
	if(defaultDevID == kAudioObjectUnknown)
		return;

	newValue = theVolume > 1.0 ? 1.0 : (theVolume < 0.0 ? 0.0 : theVolume);

	theAddress.mElement = kAudioObjectPropertyElementMain;
	theAddress.mScope = kAudioDevicePropertyScopeOutput;

	if(newValue < THRESHOLD){
		theAddress.mSelector = kAudioDevicePropertyMute;
		hasMute = AudioObjectHasProperty(defaultDevID, &theAddress);
		canMute = 0;
		if(hasMute){
			theError = AudioObjectIsPropertySettable(defaultDevID, &theAddress, &canMute);
			if(theError != noErr)
				canMute = 0;
		}
		if(hasMute && canMute){
			muted = 1;
			AudioObjectSetPropertyData(defaultDevID, &theAddress, 0, NULL, sizeof(muted), &muted);
			return;
		}
		/* can't mute, just set volume to 0 */
		newValue = 0.0;
	}

	theAddress.mSelector = kAudioDevicePropertyVolumeScalar;
	theAddress.mElement = 1; /* master/main channel */

	if(!AudioObjectHasProperty(defaultDevID, &theAddress))
		return;

	canSetVol = 0;
	theError = AudioObjectIsPropertySettable(defaultDevID, &theAddress, &canSetVol);
	if(theError != noErr || !canSetVol)
		return;

	AudioObjectSetPropertyData(defaultDevID, &theAddress, 0, NULL, sizeof(newValue), &newValue);

	/* unmute if device was muted */
	theAddress.mSelector = kAudioDevicePropertyMute;
	theAddress.mElement = kAudioObjectPropertyElementMain;
	hasMute = AudioObjectHasProperty(defaultDevID, &theAddress);
	if(hasMute){
		canMute = 0;
		AudioObjectIsPropertySettable(defaultDevID, &theAddress, &canMute);
		if(canMute){
			muted = 0;
			AudioObjectSetPropertyData(defaultDevID, &theAddress, 0, NULL, sizeof(muted), &muted);
		}
	}
}

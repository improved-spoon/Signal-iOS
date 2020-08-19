//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

#import "OWSBatchMessageProcessor.h"
#import "AppContext.h"
#import "AppReadiness.h"
#import "NSArray+OWS.h"
#import "NSNotificationCenter+OWS.h"
#import "NotificationsProtocol.h"
#import "OWSBackgroundTask.h"
#import "OWSMessageManager.h"
#import "OWSQueues.h"
#import "SSKEnvironment.h"
#import "TSAccountManager.h"
#import "TSErrorMessage.h"
#import <SignalCoreKit/Threading.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSNotificationName const kNSNotificationNameMessageProcessingDidFlushQueue
    = @"kNSNotificationNameMessageProcessingDidFlushQueue";

@implementation OWSMessageContentJob

+ (NSString *)collection
{
    return @"OWSBatchMessageProcessingJob";
}

- (instancetype)initWithEnvelopeData:(NSData *)envelopeData
                       plaintextData:(NSData *_Nullable)plaintextData
                     wasReceivedByUD:(BOOL)wasReceivedByUD
             serverDeliveryTimestamp:(uint64_t)serverDeliveryTimestamp
{
    OWSAssertDebug(envelopeData);

    self = [super init];
    if (!self) {
        return self;
    }

    _envelopeData = envelopeData;
    _plaintextData = plaintextData;
    _wasReceivedByUD = wasReceivedByUD;
    _serverDeliveryTimestamp = serverDeliveryTimestamp;
    _createdAt = [NSDate new];

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                       createdAt:(NSDate *)createdAt
                    envelopeData:(NSData *)envelopeData
                   plaintextData:(nullable NSData *)plaintextData
                 wasReceivedByUD:(BOOL)wasReceivedByUD
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId];

    if (!self) {
        return self;
    }

    _createdAt = createdAt;
    _envelopeData = envelopeData;
    _plaintextData = plaintextData;
    _wasReceivedByUD = wasReceivedByUD;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    return [super initWithCoder:coder];
}

- (nullable SSKProtoEnvelope *)envelope
{
    NSError *error;
    SSKProtoEnvelope *_Nullable result = [[SSKProtoEnvelope alloc] initWithSerializedData:self.envelopeData
                                                                                    error:&error];

    if (error) {
        OWSFailDebug(@"paring SSKProtoEnvelope failed with error: %@", error);
        return nil;
    }
    
    return result;
}

@end

#pragma mark - Queue Processing

@interface OWSMessageContentQueue : NSObject <OWSMessageProcessingPipelineStage>

@property (nonatomic, readonly) AnyMessageContentJobFinder *finder;
@property (nonatomic) BOOL isDrainingQueue;
@property (atomic) BOOL isAppInBackground;

@end

#pragma mark -

@implementation OWSMessageContentQueue

- (instancetype)init
{
    OWSSingletonAssert();

    self = [super init];
    if (!self) {
        return self;
    }

    _finder = [AnyMessageContentJobFinder new];
    _isDrainingQueue = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:OWSApplicationWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:OWSApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(registrationStateDidChange:)
                                                 name:NSNotificationNameRegistrationStateDidChange
                                               object:nil];

    // Start processing.
    [AppReadiness runNowOrWhenAppDidBecomeReady:^{
        [self.pipelineSupervisor registerPipelineStage:self];
        [self drainQueue];
    }];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.pipelineSupervisor unregisterPipelineStage:self];
}

#pragma mark - Dependencies

- (OWSMessageManager *)messageManager
{
    OWSAssertDebug(SSKEnvironment.shared.messageManager);

    return SSKEnvironment.shared.messageManager;
}

- (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);

    return SSKEnvironment.shared.tsAccountManager;
}

- (SDSDatabaseStorage *)databaseStorage
{
    return SDSDatabaseStorage.shared;
}

- (GroupsV2MessageProcessor *)groupsV2MessageProcessor
{
    return SSKEnvironment.shared.groupsV2MessageProcessor;
}

- (OWSMessagePipelineSupervisor *)pipelineSupervisor
{
    return SSKEnvironment.shared.messagePipelineSupervisor;
}

#pragma mark - Notifications

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    self.isAppInBackground = NO;
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    self.isAppInBackground = YES;
}

- (void)registrationStateDidChange:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    [AppReadiness runNowOrWhenAppDidBecomeReady:^{ [self drainQueue]; }];
}

#pragma mark - instance methods

- (dispatch_queue_t)serialQueue
{
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("org.whispersystems.message.process", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

- (void)enqueueEnvelopeData:(NSData *)envelopeData
              plaintextData:(NSData *_Nullable)plaintextData
            wasReceivedByUD:(BOOL)wasReceivedByUD
    serverDeliveryTimestamp:(uint64_t)serverDeliveryTimestamp
                transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(envelopeData);
    OWSAssertDebug(transaction);

    // We need to persist the decrypted envelope data ASAP to prevent data loss.
    [self.finder addJobWithEnvelopeData:envelopeData
                          plaintextData:plaintextData
                        wasReceivedByUD:wasReceivedByUD
                serverDeliveryTimestamp:serverDeliveryTimestamp
                            transaction:transaction];
}

- (BOOL)hasPendingJobsWithTransaction:(SDSAnyReadTransaction *)transaction
{
    return [self.finder jobCountWithTransaction:transaction] > 0;
}

- (void)drainQueue
{
    OWSAssertDebugUnlessRunningTests(AppReadiness.isAppReady);
    if (!self.pipelineSupervisor.isMessageProcessingPermitted) {
        return;
    }
    if (!self.tsAccountManager.isRegisteredAndReady) {
        return;
    }

    dispatch_async(self.serialQueue, ^{
        if (self.isDrainingQueue) {
            return;
        }
        self.isDrainingQueue = YES;
        
        [self drainQueueWorkStep];
    });
}

- (void)drainQueueWorkStep
{
    AssertOnDispatchQueue(self.serialQueue);

    if (SSKDebugFlags.suppressBackgroundActivity) {
        // Don't process queues.
        return;
    }

    // We want a value that is just high enough to yield perf benefits.
    const NSUInteger kIncomingMessageBatchSize = 32;
    // If the app is in the background, use batch size of 1.
    // This reduces the cost of being interrupted and rolled back if
    // app is suspended.
    NSUInteger batchSize = self.isAppInBackground ? 1 : kIncomingMessageBatchSize;

    __block NSArray<OWSMessageContentJob *> *batchJobs;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        batchJobs = [self.finder nextJobsWithBatchSize:batchSize transaction:transaction];
    }];
    OWSAssertDebug(batchJobs);
    if (batchJobs.count < 1) {
        self.isDrainingQueue = NO;
        OWSLogVerbose(@"Queue is drained");

        [[NSNotificationCenter defaultCenter]
            postNotificationNameAsync:kNSNotificationNameMessageProcessingDidFlushQueue
                               object:nil
                             userInfo:nil];

        return;
    }

    OWSBackgroundTask *_Nullable backgroundTask = [OWSBackgroundTask backgroundTaskWithLabelStr:__PRETTY_FUNCTION__];

    __block NSArray<OWSMessageContentJob *> *processedJobs;
    __block NSUInteger jobCount;
    DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        processedJobs = [self processJobs:batchJobs transaction:transaction];
        
        [self.finder removeJobsWithUniqueIds:processedJobs.uniqueIds transaction:transaction];
        
        jobCount = [self.finder jobCountWithTransaction:transaction];
    });

    OWSAssertDebug(backgroundTask);
    backgroundTask = nil;

    OWSLogVerbose(@"completed %lu/%lu jobs. %lu jobs left.",
        (unsigned long)processedJobs.count,
        (unsigned long)batchJobs.count,
        (unsigned long)jobCount);

    // Wait a bit in hopes of increasing the batch size.
    // This delay won't affect the first message to arrive when this queue is idle,
    // so by definition we're receiving more than one message and can benefit from
    // batching.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5f * NSEC_PER_SEC)), self.serialQueue, ^{
        [self drainQueueWorkStep];
    });
}

- (NSArray<OWSMessageContentJob *> *)processJobs:(NSArray<OWSMessageContentJob *> *)jobs
                                     transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(jobs.count > 0);
    OWSAssertDebug(transaction != nil);

    NSMutableArray<OWSMessageContentJob *> *processedJobs = [NSMutableArray new];
    for (OWSMessageContentJob *job in jobs) {

        void (^reportFailure)(SDSAnyWriteTransaction *transaction) = ^(SDSAnyWriteTransaction *transaction) {
            // TODO: Add analytics.
            ThreadlessErrorMessage *errorMessage = [ThreadlessErrorMessage corruptedMessageInUnknownThread];
            [SSKEnvironment.shared.notificationsManager notifyUserForThreadlessErrorMessage:errorMessage
                                                                                transaction:transaction];
        };

        SSKProtoEnvelope *_Nullable envelope = job.envelope;
        if (!envelope) {
            reportFailure(transaction);
        } else if ([GroupsV2MessageProcessor isGroupsV2MessageWithEnvelope:envelope plaintextData:job.plaintextData]) {
            [self.groupsV2MessageProcessor enqueueWithEnvelopeData:job.envelopeData
                                                     plaintextData:job.plaintextData
                                                          envelope:envelope
                                                   wasReceivedByUD:job.wasReceivedByUD
                                           serverDeliveryTimestamp:job.serverDeliveryTimestamp
                                                       transaction:transaction];
        } else {
            if (![self.messageManager processEnvelope:envelope
                                        plaintextData:job.plaintextData
                                      wasReceivedByUD:job.wasReceivedByUD
                              serverDeliveryTimestamp:job.serverDeliveryTimestamp
                                          transaction:transaction]) {
                reportFailure(transaction);
            }
        }
        [processedJobs addObject:job];

        if (self.isAppInBackground) {
            // If the app is in the background, stop processing this batch.
            //
            // Since this check is done after processing jobs, we'll continue
            // to process jobs in batches of 1.  This reduces the cost of
            // being interrupted and rolled back if app is suspended.
            break;
        }
    }
    return processedJobs;
}

#pragma mark - <OWSMessageProcessingPipelineStage>

- (void)supervisorDidResumeMessageProcessing:(OWSMessagePipelineSupervisor *)supervisor
{
    [AppReadiness runNowOrWhenAppDidBecomeReady:^{ [self drainQueue]; }];
}

@end

#pragma mark - OWSBatchMessageProcessor

@interface OWSBatchMessageProcessor ()

@property (nonatomic, readonly) OWSMessageContentQueue *processingQueue;

@end

#pragma mark -

@implementation OWSBatchMessageProcessor

- (instancetype)init
{
    OWSSingletonAssert();

    self = [super init];
    if (!self) {
        return self;
    }

    _processingQueue = [OWSMessageContentQueue new];

    [AppReadiness runNowOrWhenAppDidBecomeReady:^{ [self.processingQueue drainQueue]; }];

    return self;
}

#pragma mark - instance methods

- (void)enqueueEnvelopeData:(NSData *)envelopeData
              plaintextData:(NSData *_Nullable)plaintextData
            wasReceivedByUD:(BOOL)wasReceivedByUD
    serverDeliveryTimestamp:(uint64_t)serverDeliveryTimestamp
                transaction:(SDSAnyWriteTransaction *)transaction
{
    if (envelopeData.length < 1) {
        OWSFailDebug(@"Empty envelope.");
        return;
    }
    OWSAssert(transaction);

    // We need to persist the decrypted envelope data ASAP to prevent data loss.
    [self.processingQueue enqueueEnvelopeData:envelopeData
                                plaintextData:plaintextData
                              wasReceivedByUD:wasReceivedByUD
                      serverDeliveryTimestamp:serverDeliveryTimestamp
                                  transaction:transaction];

    // The new envelope won't be visible to the finder until this transaction commits,
    // so drainQueue in the transaction completion.
    [transaction addAsyncCompletionWithQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
                                       block:^{
                                           [self.processingQueue drainQueue];
                                       }];
}

- (BOOL)hasPendingJobsWithTransaction:(SDSAnyReadTransaction *)transaction
{
    return [self.processingQueue hasPendingJobsWithTransaction:transaction];
}

@end

NS_ASSUME_NONNULL_END

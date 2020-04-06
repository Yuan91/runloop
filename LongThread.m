//
//  LongThread.m
//  runloopTest
//
//  Created by du on 2020/4/5.
//  Copyright © 2020 du. All rights reserved.
//

#import "LongThread.h"
@interface XXThread: NSThread
@end

@implementation XXThread

- (void)dealloc{
    NSLog(@"%s",__func__);
}

@end


//#define USE_CoreFoundation

@interface LongThread ()

@property (nonatomic,strong) XXThread *thread;
@property (nonatomic,assign) BOOL exitRunloop;

@end

@implementation LongThread

+ (instancetype)thread{
    LongThread *l = [[LongThread alloc]init];
    return l;
}

#ifdef USE_CoreFoundation
- (instancetype)init{
    self = [super init];
    if (self) {
        _thread = [[XXThread alloc]initWithBlock:^{
            //基于CoreFoundation 实现
            CFRunLoopSourceContext context = {0};
            CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
            CFRelease(source);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0e10, false);
        }];
        [_thread start];
    }
    return self;
}

#else
- (instancetype)init{
    self = [super init];
    if (self) {
        _exitRunloop = NO;
        __weak typeof(self) weakSelf = self;
        _thread = [[XXThread alloc]initWithBlock:^{

            //基于Foundation实现
            [[NSRunLoop currentRunLoop]addPort:[NSPort port]
                                       forMode:NSDefaultRunLoopMode];
            while (weakSelf && !weakSelf.exitRunloop) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate distantFuture]];
            }
        }];
        [_thread start];
    }
    return self;
}
#endif


- (void)doTask:(ThreadBlock)block{
    if(self.thread == nil){
        return;
    }
    
    [self performSelector:@selector(__doTask:) onThread:self.thread withObject:block waitUntilDone:NO];
}

- (void)stop{
    if(self.thread == nil){
        return;
    }
    
    [self performSelector:@selector(__stop) onThread:self.thread withObject:nil waitUntilDone:YES];
}

#pragma mark - private -
- (void)dealloc{
    NSLog(@"%s",__func__);
    [self stop];
}



#ifdef USE_CoreFoundation
- (void)__stop{
    CFRunLoopStop(CFRunLoopGetCurrent());
    self.thread = nil;
}
#else
- (void)__stop{
    self.exitRunloop = YES;
    CFRunLoopStop(CFRunLoopGetCurrent());
    self.thread = nil;
}
#endif



- (void)__doTask:(ThreadBlock)block{
    if (block) {
        block();
    }
}


@end

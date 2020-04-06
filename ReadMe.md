# runloop 总结

先由一个例子看一下`runloop`的作用.猜想一下下面代码会如何工作
```
-(void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        NSLog(@"任务A");
    }];
    [thread start];
    [self performSelector:@selector(test) onThread:thread withObject:nil waitUntilDone:YES];
}

- (void)test{
    NSLog(@"任务B");
}
```
运行之后点击控制器,程序会崩溃.
```
任务A
*** Terminating app due to uncaught exception 'NSDestinationInvalidException', reason: '*** -[ViewController performSelector:onThread:withObject:waitUntilDone:modes:]: target thread exited while waiting for the perform'
```
可以看到线程在等待执行`performSelector`的时候,已经退出.这是因为线程并没有一个与之对应的`runloop`对象,所以线程无法正确的执行任务.如果想要线程正确运行,我们可以做如下修改
```
-(void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        NSLog(@"任务A");
        [[NSRunLoop currentRunLoop] addPort:[[NSPort alloc] init] forMode:NSDefaultRunLoopMode];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate distantFuture]];
    }];
    [thread start];
    [self performSelector:@selector(test) onThread:thread withObject:nil waitUntilDone:YES];
}
```
需要说明的是:
* 获取/创建`runloop`之后,必须要为其添加`Timer`/`Port`/`Source`/`Observer`,否则runloop会退出,线程也无法正确的执行任务
* 创建`NSThread`可以通过`initWithBlock`或`initWithSelector`这个参数更多的是做`runloop`的初始化操作,执行线程的任务,一般放在`performSelector`中执行.

## runloop 数据结构介绍
在iOS中,我们想要调用`runloop`有两种方式:
* `CoreFoundation`层面:`CFRunLoopRef`
* `Foundation`层面:`NSRunLoop`,它是`CFRunLoopRef`的OC封装

查看[runloop的源码](https://opensource.apple.com/tarballs/CF/),可以发现`CFRunLoopRef`由以下几部分构成
* CFRunLoopRef
* CFRunLoopModeRef
* CFRunLoopSourceRef
* CFRunLoopTimerRef
* CFRunLoopObserverRef

它们之间的关系如下:
![avatar](https://blog.ibireme.com/wp-content/uploads/2015/05/RunLoop_0.png)
总结来说就是,我们常说的`runloop`在`CoreFoundation`的表现就是一个`CFRunLoopRef`对象,它由若干个`CFRunLoopModeRef`组成.
每个`CFRunLoopModeRef`又包含一个`CFRunLoopSourceRef`的集合,`CFRunLoopTimerRef`类型的数组和`CFRunLoopObserverRef`类型的数组.

### CFRunLoopModeRef 简介
查看源码,`CFRunLoopModeRef`的数据结构如下
```
struct __CFRunLoopMode {
    CFRuntimeBase _base;
    pthread_mutex_t _lock;	/* must have the run loop locked before locking this */
    CFStringRef _name; // name
    Boolean _stopped; // 是否停止
    char _padding[3];

    //mode 中最核心的四个元素
    CFMutableSetRef _sources0; //source0, 这是一个set
    CFMutableSetRef _sources1; // source1, set
    CFMutableArrayRef _observers; // observer,  数组类型
    CFMutableArrayRef _timers; //timers, 数组类型

    CFIndex _observerMask;
    ...
};
```
* `CFRunLoopModeRef`代表着`Runloop`的工作模式,在同一个时间`runloop`只能选择工作在一个`mode`,并将该`mode`设定为`currentMode`
* 如果要切换`mode`,必须退出当前`loop`,再选择一个`mode`重新进入
* 不同mode下的Source0/Source1/Timer/Observer 是分隔开的,互不影响
* 如果Mode 里没有Source0/Source1/Timer/Observer ,runloop 会立刻退出

开发中默认的工作模式是`kCFRunLoopDefaultMode`,当`scrollView`滑动的时候处于`UITrackingRunLoopMode`.这两个是经常会遇到的`runloop`工作模式.一个老生常谈的问题是:`scrollView`滑动时,`NSTimer`将停止运行,这是因为`NSTimer`默认是在`kCFRunLoopDefaultMode`工作的,当前`scrollView`滑动时`runloop`会切换到`UITrackingRunLoopMode`,`kCFRunLoopDefaultMode`停止工作,所以定时器不会在定时执行方法.

### CFRunLoopSourceRef 简介
CFRunLoopSourceRef 有`Source0`和`Source1`两种.
* `Source1`用来处理基于`Port`的进程间通信.比如触摸屏幕/点击事件/手势,是由硬件监测,再通过进程间通信传递到我们的应用.所以检测用户输入是一个`Source1`事件
* `Source0`只包含了一个回调（函数指针），它并不能主动触发事件.

### CFRunLoopTimerRef
CFRunLoopTimerRef 它对应的是`Foundation`层面的`NSTimer`

### CFRunLoopObserverRef 
`CFRunLoopObserverRef` 用来监听`runloop`的状态,每一次`runloop`状态变化都会知道到它的观察者.`runloop`有以下几种状态组成
```
typedef CF_OPTIONS(CFOptionFlags, CFRunLoopActivity) {
    kCFRunLoopEntry = (1UL << 0), //进入runloop
    kCFRunLoopBeforeTimers = (1UL << 1), //处理timers之前
    kCFRunLoopBeforeSources = (1UL << 2), //处理source之前
    kCFRunLoopBeforeWaiting = (1UL << 5), //代表一个时间段:睡眠之前,等待唤醒的一段时间
    kCFRunLoopAfterWaiting = (1UL << 6), //代表一个时间段:唤醒之后,处理事件之前的一段时间
    kCFRunLoopExit = (1UL << 7), //退出了runloop
    kCFRunLoopAllActivities = 0x0FFFFFFFU
};
```
创建`runloop`之后,我们可以通过如下代码检测它的状态:
```
- (void)addRlo{
CFRunLoopObserverRef rlo = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopAllActivities, YES, 0, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
       switch (activity) {
           case kCFRunLoopEntry:
               NSLog(@"进入runloop");
               break;
           
               case kCFRunLoopBeforeTimers:
               NSLog(@"处理timers之前");
               break;
               
               case kCFRunLoopBeforeSources:
               NSLog(@"处理source之前");
               break;
               
               //睡眠之前,等待timer或source唤醒
               case kCFRunLoopBeforeWaiting:
               NSLog(@"------->睡眠之前,等待唤醒");
               break;
               
               //代表一个时间段,runloop被唤醒之后,处理唤醒事件之前的一段时间.
               case kCFRunLoopAfterWaiting:
               NSLog(@"------->唤醒之后,处理事件之前");
               break;
               
               case kCFRunLoopExit:
               NSLog(@"退出了runloop");
               break;
               
           default:
               break;
       }
   });
   
   CFRunLoopRef rl = CFRunLoopGetCurrent();
   
   CFRunLoopAddObserver(rl, rlo, kCFRunLoopDefaultMode);
   
   CFRelease(rlo);
}
```

## runloop 的作用

### runloop 是什么?
`runloop`的核心是一个`do-while`循环,提供了一套让线程有事件的时候处理事件,没有事件的时候休眠的机制.
它提供了一个runloop对象来管理其所需要处理的事件和消息,并且提供了一个`run`函数,来执行这个`do-while`循环.
它伪代码实现如下:
```
-(void)run{
    int retVal = 0;
    do{
        //休眠的同时等待消息
        int message = sleep_and_wait();
        //接受到消息之后,处理消息
        retVal = process_message(message);
    }while(ret == retVal)
}
```

### runloop 的作用
* 保证iOS应用的存活,在`main`函数中`UIApplicationMain(argc, argv, nil, appDelegateClassName)`开启了主线程的`runloop`,保证了应用不会启动之后立马退出
* 处理App中的各种事件:触摸事件/定时器事件/界面刷新/autoreleasepool 等
* 节省CPU资源,提高程序性能:该做事时做事,该休眠时休眠

### runloop 与线程的关系
* 默认情况下,线程执行完任务就会结束,`runloop`的这种`do-while`机制,提供了一种保住线程的能力.

* 子线程要想正常工作,必须创建一个与之对应的`runloop`对象:
①要向`runloop`中添加`Source/Timer/Observer`,没有这些`runloop`会立刻退出
②调用它的`run`/`runMode:beforeDate`方法.没有调用,不会启动`do-while`循环

* 主线程的`runloop`是默认创建且开启的

* 每条线程都有一个唯一与之对应的`runloop`对象,这种对应关系存在一个**全局的字典**中,线程作为key,`runloop`作为value

## 实现一条常驻线程

假如我们需要频繁的在子线程中做事情,但是每次创建线程,销毁线程都会有较大的系统资源开销.这个时候,我们就需要一条常驻线程来实现目的.
实际开发中,实现一个常驻线程是比较容易的,创建`runloop`/添加`Port`/调用`run`方法,即可很快的实现一条常驻线程.但是这条线程如何销毁其实是问题比较大的
具体的实现,可以参考[LongThread](https://github.com/Yuan91/runloop/blob/master/LongThread.m).提供了`Foundation`和`CoreFoundation`的两种实现.在实现过程中发现,有以下细节要注意.

### 细节1:NSRunloop的run方法,无法停止
查看定义:
>In other words, this method effectively begins an infinite loop that processes data from the run loop’s input sources and timers.

它高效的开启了无限循环的`runloop`来处理`source`和`timers`的输入数据.相当于这是一个死循环,即便你可以通过`CFRunLoopStop(CFRunLoopGetCurrent());`停掉其中一次`runloop`,它仍然处在一个while(1)循环中,还是是无法停止的.
```
while(1){
    //runloop
    int retVal = 0;
    do{
        int message = sleep_and_wait();
        retVal = process_message(message);
    }while(ret == retVal)
}
```
为了解决这个问题,我们有两个方案可选
* 采用`NSRunloop`层面的`runMode:beforeDate`方法
* 采用`CoreFoundation`层面的`CFRunLoopRunInMode`函数

### 细节2:如何在dealloc中关闭runloop
```
- (void)stopThread{
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)dealloc{
    NSLog(@"%s",__func__);
    [self performSelector:@selector(stopThread) onThread:self.thread withObject:nil waitUntilDone:NO];
}
```
以上程序在控制器释放的时候会崩溃,因为`waitUntilDone:NO`这个参数决定了是在子线程异步去关闭runloop,但是在此时可能主线程中控制对象已经释放掉了,如果再在子线程中去访问控制器的属性,是会造成坏访问的.
解决:`waitUntilDone`参数改为`YES`

### 细节3:如何正确判断的停掉runloop
```
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    self.stop = NO;
    __weak typeof(self) weakSelf = self;
    MyThread *thread = [[MyThread alloc]initWithBlock:^{
        [[NSRunLoop currentRunLoop] addPort:[NSPort port] forMode:NSDefaultRunLoopMode];       
        while (!weakSelf.isStopped) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate distantFuture]];
        }
    }];
    self.thread = thread;
    [thread start];
    
}
```
在将`waitUntilDone`改为YES后,控制器销毁,self=nil,!weakSelf.isStopped为YES,所以仍然不能正确的停止.
故正确的判断逻辑应该是:
```
while (weakSelf && !weakSelf.isStopped) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate distantFuture]];
}
```

### 另外两个细节
* `initWithTarget`创建的线程,会对控制器有一个强引用,为了避免循环引用我们尽量用`initWithBlock`方法创建
* 假如线程已经`exited`,但是线程对象依然处在存活状态,在执行`perfomSelector:onThread`会崩溃,所以在`stopThread`应该把线程置位nil
```
- (void)stopThread{
    CFRunLoopStop(CFRunLoopGetCurrent());
    self.thread = nil;
}
```

## runloop 核心代码剖析
借用YYKit作者的一张图,先直观的看一下`runloop`的运行逻辑.
![avatar](https://blog.ibireme.com/wp-content/uploads/2015/05/RunLoop_1.png)
需要说明的是,这个图左边`Source0(Port)`唤醒`runloop`应该是原作者笔误,应该是`Source1(Port)`.因为`Source0`不是基于`Port`的,`Source1`才是;另外`Source0`也不备注主动唤醒`runloop`的能力

### CFRunLoopRun 分析
```
void CFRunLoopRun(void) {	
    int32_t result;
    do {
        result = CFRunLoopRunSpecific(CFRunLoopGetCurrent(), 
        kCFRunLoopDefaultMode, 
        1.0e10, 
        false);
    } while (kCFRunLoopRunStopped != result && kCFRunLoopRunFinished != result);
    //非 kCFRunLoopRunStopped 和 kCFRunLoopRunFinished 一直循环
}
```
只要`runloop`的状态不是`kCFRunLoopRunStopped`和`kCFRunLoopRunFinished`, `runloop`就会一直运行.这也就是为什么我们在程序在执行完`UIApplicationMain`不会挂掉的原因.

### CFRunLoopRunSpecific 分析
```
SInt32 CFRunLoopRunSpecific(CFRunLoopRef rl, CFStringRef modeName, CFTimeInterval seconds, Boolean returnAfterSourceHandled) {    
    
    CFRunLoopModeRef currentMode = __CFRunLoopFindMode(rl, modeName, false);
    
    //1.通知Observer 进入 currentMode,对应上图的第1步
	if (currentMode->_observerMask & kCFRunLoopEntry ) __CFRunLoopDoObservers(rl, currentMode, kCFRunLoopEntry);
    
    //这个地方是runloop真正进入循环的入口,对应图上的第2-9步,其内部也是一个do-while循环
	result = __CFRunLoopRun(rl, currentMode, seconds, returnAfterSourceHandled, previousMode);
    
    //10.通知Observer 退出 currentMode,对应上图的第10步
	if (currentMode->_observerMask & kCFRunLoopExit ) __CFRunLoopDoObservers(rl, currentMode, kCFRunLoopExit);

    return result;
}
```
该函数会通知`Observer`即将进入`runloop`和退出`runloop`,进入`runloop`后的操作在`__CFRunLoopRun`中实现,其内部也是`do-while`循环保证了线程在当前mode下,能够有事做事无事休眠的逻辑.
两层`do-while`循环的设计是因为:内层的`do-while`循环在切换`mode`的时候,会退出当前循环.如果只有一层循环,是无法保证程序一直运行的.

### __CFRunLoopRun分析
```
__CFRunLoopRun(runloop, currentMode, seconds, returnAfterSourceHandled) {
        
        Boolean sourceHandledThisLoop = NO;
        int retVal = 0;
        do {
 
            /// 2. 通知 Observers: RunLoop 即将触发 Timer 回调。
            __CFRunLoopDoObservers(runloop, currentMode, kCFRunLoopBeforeTimers);
            /// 3. 通知 Observers: RunLoop 即将触发 Source0 (非port) 回调。
            __CFRunLoopDoObservers(runloop, currentMode, kCFRunLoopBeforeSources);
            /// 执行被加入的block
            __CFRunLoopDoBlocks(runloop, currentMode);
            
            /// 4. RunLoop 触发 Source0 (非port) 回调。
            sourceHandledThisLoop = __CFRunLoopDoSources0(runloop, currentMode, stopAfterHandle);
            /// 执行被加入的block
            __CFRunLoopDoBlocks(runloop, currentMode);
 
            /// 5. 如果有 Source1 (基于port) 处于 ready 状态，直接处理这个 Source1 然后跳转去处理消息。
            if (__Source0DidDispatchPortLastTime) {
                Boolean hasMsg = __CFRunLoopServiceMachPort(dispatchPort, &msg)
                if (hasMsg) goto handle_msg;
            }
            
            /// 通知 Observers: RunLoop 的线程即将进入休眠(sleep)。
            if (!sourceHandledThisLoop) {
                __CFRunLoopDoObservers(runloop, currentMode, kCFRunLoopBeforeWaiting);
            }
            
            /// 7. 调用 mach_msg 等待接收消息。线程将进入休眠, 直到被下面某一个事件唤醒。
            /// • 一个基于 port 的Source 的事件,如用户点击/触摸灯事件
            /// • 一个 Timer 到时间了
            /// • RunLoop 自身的超时时间到了
            /// • 如果有dispatch到main_queue的block
            __CFRunLoopServiceMachPort(waitSet, &msg, sizeof(msg_buffer), &livePort) {
                mach_msg(msg, MACH_RCV_MSG, port); // thread wait for receive msg
            }
 
            /// 8. 通知 Observers: RunLoop 的线程刚刚被唤醒了。
            __CFRunLoopDoObservers(runloop, currentMode, kCFRunLoopAfterWaiting);
            
            /// 收到消息，处理消息。
            handle_msg:
 
            /// 9.1 如果一个 Timer 到时间了，触发这个Timer的回调。
            if (msg_is_timer) {
                __CFRunLoopDoTimers(runloop, currentMode, mach_absolute_time())
            } 
 
            /// 9.2 如果有dispatch到main_queue的block，执行block。
            else if (msg_is_dispatch) {
                __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__(msg);
            } 
 
            /// 9.3 如果一个 Source1 (基于port) 发出事件了，处理这个事件
            else {
                CFRunLoopSourceRef source1 = __CFRunLoopModeFindSourceForMachPort(runloop, currentMode, livePort);
                sourceHandledThisLoop = __CFRunLoopDoSource1(runloop, currentMode, source1, msg);
                if (sourceHandledThisLoop) {
                    mach_msg(reply, MACH_SEND_MSG, reply);
                }
            }
            
            /// 执行加入到Loop的block
            __CFRunLoopDoBlocks(runloop, currentMode);
            
 
            if (sourceHandledThisLoop && stopAfterHandle) {
                /// 进入loop时参数说处理完事件就返回。
                retVal = kCFRunLoopRunHandledSource;
            } else if (timeout) {
                /// 超出传入参数标记的超时时间了
                retVal = kCFRunLoopRunTimedOut;
            } else if (__CFRunLoopIsStopped(runloop)) {
                /// 被外部调用者强制停止了
                retVal = kCFRunLoopRunStopped;
            } else if (__CFRunLoopModeIsEmpty(runloop, currentMode)) {
                /// source/timer/observer一个都没有了
                retVal = kCFRunLoopRunFinished;
            }
            
            /// 如果没超时，mode里没空，loop也没被停止，那继续loop。
        } while (retVal == 0);
    }
```
以上即`runloop`执行流程图中第2-9步的执行逻辑.对以上关键点做以下解析:

#### 休眠的理解
第7步调用`mach_msg`之后,程序是由用户态进入了内核态,达到线程有事做事,无事休眠的状态.这种状态和`sleep(1)`是不一样,它会卡着线程,无法处理任何输入输出事件;和`while`循环也不一样,这会让程序一直循环处理任务,没有达到节省资源的目的.调用`mach_msg`之后,程序相当于处在`一个卡住`的状态,后面的代码不会继续执行,直到有输入源唤醒了`run loop`,执行完唤醒事件,如果`runloop`没有退出,则继续执行下一次循环.

#### 唤醒runloop
唤醒runloop的有以下三种类型事件:
* Source1,也即Port通信.例如用户点击/触摸屏幕/手势
* Timer,当定时器的时间达到之后,会唤醒`runloop`执行事件
* dispatch_async(dispatch_get_main_queue(), block) 调用.libDispatch会向主线程`runloop`发送消息唤醒主线程`runloop`.libDispatch唤醒`runloop`仅限主线程,`dispatch`到其他线程仍由`libDispatch`处理.

#### 关于__CFRunLoopDoSource1/__CFRunLoopDoTimer 等的理解
在runloop源码中,可以看到这些do函数内部都调用了一个很长的`calling_out`函数,这些函数的目的在于将`runloop`中接受的事件从系统的Runloop层面传递到上层,中间可能会经过一些额外的处理,最终到达程序员所编写的代码层面.
```
    static void __CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__();
    static void __CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__();
    static void __CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__();
    static void __CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__();
    static void __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__();
    static void __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__();
```


## runloop 接收事件和处理事件
当我们讨论runloop时,探讨其与线程的关系是最多的.这一方面是因为在创建子线程的时候,必须获取一个对应的runloop对象,另外我们能够方便直观的创建线程来探索两者之间的关系.

其实runloop的事件机制,在App中有更为底层的应用,只不过这些机制被系统很好的隐藏了实现的细节,我们很难一窥究竟.但是我们通过在程序启动之后打印`currenMode`/符号断点/LLDB的`bt`命令,查看其中的细节.

runloop 在程序启动的时候,注册一些观察者,这些观察在接收到事件的时候,会在runloop的合适时机出执行这些事件.

### 事件响应和手势识别
添加符号断点:`__IOHIDEventSystemClientQueueCallback`
在应用启动后,苹果注册了一个`Source1`用来接收用户输入事件,如触摸屏幕/点击事件/手势等,其回调函数为`__IOHIDEventSystemClientQueueCallback`.

用户输入-->硬件监测到`IOHIDEvent` --> mach port 发送消息给App进程 --> 注册的Source1 触发 --> _UIApplicationHandleEventQueue()调用,进行事件分发.

_UIApplicationHandleEventQueue() --> 识别为 UIEvent,如UIButton click、touchesBegin/Move/End/Cancel 
_UIApplicationHandleEventQueue() --> 识别为UIGestureRecognizer


### AutoReleasePool
符号断点:_wrapRunLoopWithAutoreleasePoolHandler
应用启动后,runloop注册了两个Observer,这两个观察者的callback都是`_wrapRunLoopWithAutoreleasePoolHandler`.

第一个观察者监测的事件是:即将进入runloop(kCFRunLoopEntry),此时会调用`objc_autoreleasePoolPush`创建自动释放池,这个活动优先级最高,确保在进入`runloop`的时候,自动释放池已经创建好了.

第二个观察者监测了两个事件:`kCFRunLoopBeforeWaiting`和`kCFRunLoopExit`,此时会调用`_objc_autoreleasePoolPop() `和`_objc_autoreleasePoolPush() `释放旧池创建新池.它的优先级是最低的,确保释放自动池在其他回调之后.

监听了`kCFRunLoopBeforeWaiting`事件给与自动释放在程序空闲的时候释放内存的能力,即不占用其他回调的处理周期,又可以有效避免出现内存高峰.

### 界面更新
符号断点:ZN2CA11Transaction17observer_callbackEP19__CFRunLoopObservermPv
应用启动后会注册一个观察者,监听监听 `kCFRunLoopBeforeWaiting`(即将进入休眠) 和 `kCFRunLoopExit` (即将退出Loop) 事件,其回调是`_ZN2CA11Transaction17observer_callbackEP19__CFRunLoopObservermPv()`.

当我们在程序中,修改了`Frame`/更改了View层级/调用`setNeedsLayout`/`setNeedsDisplay` 后,这些动作其实不是被立即执行的,它被提交到一个全局的容器中,当`runloop`处于即将休眠的时候,会通知该观察者,此时去更新界面层级与布局

### 定时器
一个`NSTimer`注册到runloop后,会计算好其回调的时间点,到时间会唤醒runloop执行回调事件

Timer有一个属性Tolerance(宽容度),标记了到时候后容许有多大的误差.假如到时间后,正好有事件占用这次loop循环,且执行之后这个时间已经超过了这个宽容度,那么这次Timer事件回调会被跳过.

### PerformSelector
其内部也会创建一个Timer,并添加到当前线程的runloop中,如果当前线程没有runloop则Timer也会失效.

### 关于GCD
当调用 `dispatch_async(dispatch_get_main_queue(), block)` 时，`libDispatch` 会向主线程的 `RunLoop` 发送消息，`RunLoop`会被唤醒，并从消息中取得这个 `block`，并在回调`__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__()` 里执行这个 `block`。但这个逻辑仅限于 `dispatch` 到主线程，`dispatch` 到其他线程仍然是由 `libDispatch` 处理的

## runloop 在项目中的使用

### 常驻线程的实现.
上面已经实现
具体参数 [LongThread](https://github.com/Yuan91/runloop/blob/master/LongThread.m)

### 处理UITableView卡顿
实现`UITableView`滑动的时候,不加载图片的方法:
我们知道`UITableView`滑动是在`UITrackingMode`,我们只需要把图片的加载放在`NSRunLoopDefaultMode`即可.即调用以下方法:
```
- (void)performSelector:(SEL)aSelector withObject:(nullable id)anArgument afterDelay:(NSTimeInterval)delay inModes:(NSArray<NSRunLoopMode> *)modes
```





//
//  LongThread.h
//  runloopTest
//
//  Created by du on 2020/4/5.
//  Copyright © 2020 du. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void(^ThreadBlock)(void);

NS_ASSUME_NONNULL_BEGIN

@interface LongThread : NSObject

+ (instancetype)thread;

- (void)doTask:(ThreadBlock)block;

- (void)stop;

@end

NS_ASSUME_NONNULL_END

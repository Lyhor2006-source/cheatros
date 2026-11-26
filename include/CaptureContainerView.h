#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Non-focusable UITextField subclass used solely to host iOS's secure layer canvas
// so content placed inside `secureCanvas` is omitted from screen recordings/captures.
@interface CaptureTextField : UITextField
@end

@interface CaptureContainerView : UIView

@property (nonatomic, strong) CaptureTextField* secureField;
@property (nonatomic, weak, nullable) UIView* secureCanvas;
@property (nonatomic, strong, nullable) UIView* contentView;

- (void)attachContent:(UIView*)content;

@end

NS_ASSUME_NONNULL_END

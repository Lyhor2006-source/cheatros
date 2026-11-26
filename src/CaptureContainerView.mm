#import "CaptureContainerView.h"

@implementation CaptureTextField

- (BOOL)canBecomeFirstResponder {
    return NO;
}

- (BOOL)becomeFirstResponder {
    return NO;
}

- (BOOL)canPerformAction:(SEL)action withSender:(nullable id)sender {
    (void)action;
    (void)sender;
    return NO;
}

@end

static UIView* _Nullable FindSecureCanvasInView(UIView* _Nullable root) {
    if (!root) return nil;
    NSString* clsName = NSStringFromClass([root class]);
    if ([clsName isEqualToString:@"_UITextLayoutCanvasView"] ||
        [clsName isEqualToString:@"_UITextFieldCanvasView"] ||
        [clsName isEqualToString:@"_UISecureContainerView"]) {
        return root;
    }
    for (UIView* child in root.subviews) {
        UIView* found = FindSecureCanvasInView(child);
        if (found) return found;
    }
    return nil;
}

@implementation CaptureContainerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _secureField = [[CaptureTextField alloc] initWithFrame:self.bounds];
        _secureField.backgroundColor = [UIColor clearColor];
        _secureField.opaque = NO;
        _secureField.textColor = [UIColor clearColor];
        _secureField.tintColor = [UIColor clearColor];
        _secureField.borderStyle = UITextBorderStyleNone;
        _secureField.userInteractionEnabled = NO;
        _secureField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _secureField.secureTextEntry = YES;
        [self addSubview:_secureField];

        // Trigger lazy creation of the internal secure text canvas hierarchy.
        _secureField.text = @" ";
        [_secureField layoutIfNeeded];
        _secureField.text = @"";
    }
    return self;
}

- (void)attachContent:(UIView*)content {
    if (!self.secureCanvas || ![self.secureCanvas isDescendantOfView:self.secureField]) {
        self.secureField.secureTextEntry = YES;
        [self.secureField layoutIfNeeded];
        UIView* canvas = FindSecureCanvasInView(self.secureField);
        self.secureCanvas = canvas;
        if (canvas) {
            canvas.opaque = NO;
            canvas.backgroundColor = [UIColor clearColor];
            canvas.userInteractionEnabled = YES;
        }
    }

    self.contentView = content;
    if (content.superview != self.secureCanvas) {
        UIView* target = self.secureCanvas ? self.secureCanvas : self;
        [target addSubview:content];
        content.frame = self.bounds;
        content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self setNeedsLayout];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    self.secureField.frame = b;
    if (self.secureCanvas) {
        self.secureCanvas.frame = b;
    }
    if (self.contentView) {
        self.contentView.frame = b;
    }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(nullable UIEvent*)event {
    if (!self.contentView) return NO;
    CGPoint converted = [self.contentView convertPoint:point fromView:self];
    return [self.contentView pointInside:converted withEvent:event];
}

- (nullable UIView*)hitTest:(CGPoint)point withEvent:(nullable UIEvent*)event {
    if (!self.contentView) return nil;
    CGPoint converted = [self.contentView convertPoint:point fromView:self];
    return [self.contentView hitTest:converted withEvent:event];
}

@end

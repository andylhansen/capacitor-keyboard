/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 http://www.apache.org/licenses/LICENSE-2.0
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "Keyboard.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <Capacitor/Capacitor.h>
#import <Capacitor/Capacitor-Swift.h>
#import <Capacitor/CAPBridgedPlugin.h>
#import <Capacitor/CAPBridgedJSTypes.h>

typedef enum : NSUInteger {
  ResizeNone,
  ResizeNative,
  ResizeBody,
  ResizeIonic,
} ResizePolicy;


@interface KeyboardPlugin () <UIScrollViewDelegate>

@property (readwrite, assign, nonatomic) BOOL disableScroll;
@property (readwrite, assign, nonatomic) BOOL hideFormAccessoryBar;
@property (readwrite, assign, nonatomic) BOOL keyboardIsVisible;
@property (nonatomic, readwrite) ResizePolicy keyboardResizes;
@property (readwrite, assign, nonatomic) NSString* keyboardStyle;
@property (nonatomic, readwrite) int paddingBottom;

- (void)resetPluginState;
- (void)restoreWebViewToNaturalState;

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
// suppressing warnings of the type: "Class 'KeyboardPlugin' does not conform to protocol 'CAPBridgedPlugin'"
// protocol conformance for this class is implemented by a macro and clang isn't detecting that
@implementation KeyboardPlugin

NSTimer *hideTimer;
NSString* UIClassString;
NSString* WKClassString;
NSString* UITraitsClassString;
double stageManagerOffset;

- (void)load
{
  self.disableScroll = !self.bridge.config.scrollingEnabled;

  UIClassString = [@[@"UI", @"Web", @"Browser", @"View"] componentsJoinedByString:@""];
  WKClassString = [@[@"WK", @"Content", @"View"] componentsJoinedByString:@""];
  UITraitsClassString = [@[@"UI", @"Text", @"Input", @"Traits"] componentsJoinedByString:@""];

  PluginConfig * config = [self getConfig];
  NSString * style = [config getString:@"style": nil];
  [self changeKeyboardStyle:style.uppercaseString];

  self.keyboardResizes = ResizeNative;
  NSString * resizeMode = [config getString:@"resize": nil];

  if ([resizeMode isEqualToString:@"none"]) {
    self.keyboardResizes = ResizeNone;
    NSLog(@"KeyboardPlugin: no resize");
  } else if ([resizeMode isEqualToString:@"ionic"]) {
    self.keyboardResizes = ResizeIonic;
    NSLog(@"KeyboardPlugin: resize mode - ionic");
  } else if ([resizeMode isEqualToString:@"body"]) {
    self.keyboardResizes = ResizeBody;
    NSLog(@"KeyboardPlugin: resize mode - body");
  }

  if (self.keyboardResizes == ResizeNative) {
    NSLog(@"KeyboardPlugin: resize mode - native");
  }

  // Only hide form accessory bar if not in native mode
  if (self.keyboardResizes != ResizeNative) {
    self.hideFormAccessoryBar = YES;
  } else {
    self.hideFormAccessoryBar = NO;
    NSLog(@"KeyboardPlugin: Native mode - not hiding form accessory bar");
  }
  
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  
  // Only register for keyboard notifications if not in native mode
  // In native mode, let the WebView handle keyboard notifications naturally
  if (self.keyboardResizes != ResizeNative) {
    [nc addObserver:self selector:@selector(onKeyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    
    [nc removeObserver:self.webView name:UIKeyboardWillHideNotification object:nil];
    [nc removeObserver:self.webView name:UIKeyboardWillShowNotification object:nil];
    [nc removeObserver:self.webView name:UIKeyboardWillChangeFrameNotification object:nil];
    [nc removeObserver:self.webView name:UIKeyboardDidChangeFrameNotification object:nil];
  } else {
    NSLog(@"KeyboardPlugin: Native mode - not registering keyboard observers, letting WebView handle naturally");
  }
}


#pragma mark Keyboard events

- (void)resetScrollView
{
  UIScrollView *scrollView = [self.webView scrollView];
  [scrollView setContentInset:UIEdgeInsetsZero];
}

- (void)resetPluginState
{
  // Reset all plugin state variables
  self.paddingBottom = 0;
  self.keyboardIsVisible = NO;
  
  // Cancel and reset hide timer
  if (hideTimer != nil) {
    [hideTimer invalidate];
    hideTimer = nil;
  }
  
  // Reset WebView frame to its natural state
  if (self.webView != nil) {
    UIWindow *window = nil;
    if ([[[UIApplication sharedApplication] delegate] respondsToSelector:@selector(window)]) {
      window = [[[UIApplication sharedApplication] delegate] window];
    }
    
    if (!window) {
      if (@available(iOS 13.0, *)) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"self isKindOfClass: %@", UIWindowScene.class];
        UIScene *scene = [UIApplication.sharedApplication.connectedScenes.allObjects filteredArrayUsingPredicate:predicate].firstObject;
        window = [[(UIWindowScene*)scene windows] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isKeyWindow == YES"]].firstObject;
      }
    }
    
    if (window) {
      CGRect windowBounds = [window bounds];
      CGRect webViewFrame = self.webView.frame;
      
      // Reset WebView to full window size
      [self.webView setFrame:CGRectMake(webViewFrame.origin.x, webViewFrame.origin.y, 
                                       windowBounds.size.width - webViewFrame.origin.x, 
                                       windowBounds.size.height - webViewFrame.origin.y)];
    }
    
    // Reset WebView scroll view state
    UIScrollView *scrollView = [self.webView scrollView];
    [scrollView setContentInset:UIEdgeInsetsZero];
    [scrollView setScrollIndicatorInsets:UIEdgeInsetsZero];
    [scrollView setContentOffset:CGPointZero];
    
    // Reset scroll view delegate based on current disableScroll setting
    if (self.disableScroll) {
      scrollView.scrollEnabled = NO;
      scrollView.delegate = self;
    } else {
      scrollView.scrollEnabled = YES;
      scrollView.delegate = nil;
    }
  }
  
  // Reset scroll view only if not switching to native mode
  if (self.keyboardResizes != ResizeNative) {
    [self resetScrollView];
  }
  
  // Reset stage manager offset for iPad
  stageManagerOffset = 0;
  
  // Cancel any pending keyboard height updates
  SEL action = @selector(_updateFrame);
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:action object:nil];
  
  NSLog(@"KeyboardPlugin: Reset plugin state for mode: %@", 
        self.keyboardResizes == ResizeNative ? @"native" : 
        self.keyboardResizes == ResizeNone ? @"none" :
        self.keyboardResizes == ResizeBody ? @"body" : @"ionic");
}

- (void)restoreWebViewToNaturalState
{
  if (self.webView == nil) {
    return;
  }
  
  NSLog(@"KeyboardPlugin: Restoring WebView to completely natural state");
  
  // Reset all WebView scroll view properties to natural state
  UIScrollView *scrollView = [self.webView scrollView];
  
  // Always enable scrolling in native mode - ignore disableScroll setting
  scrollView.scrollEnabled = YES;
  
  // Remove our delegate
  scrollView.delegate = nil;
  
  // Reset all insets and offsets
  scrollView.contentInset = UIEdgeInsetsZero;
  scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
  scrollView.contentOffset = CGPointZero;
  
  // Don't set content size - let it be natural
  
  // Reset any frame constraints that might interfere
  self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  
  // Disable the input accessory bar modifications in native mode by setting to NO
  // This will restore the original implementations if they were saved
  self.hideFormAccessoryBar = NO;
  
  NSLog(@"KeyboardPlugin: WebView restored to natural state - should now handle keyboard naturally");
}

- (void)onKeyboardWillHide:(NSNotification *)notification
{
  // Only interfere with frame changes if not in native mode
  if (self.keyboardResizes != ResizeNative) {
    [self setKeyboardHeight:0 delay:0.01];
    [self resetScrollView];
  }
  
  hideTimer = [NSTimer scheduledTimerWithTimeInterval:0 repeats:NO block:^(NSTimer * _Nonnull timer) {
    [self.bridge triggerWindowJSEventWithEventName:@"keyboardWillHide"];
    [self notifyListeners:@"keyboardWillHide" data:nil];
  }];
  [[NSRunLoop currentRunLoop] addTimer:hideTimer forMode:NSRunLoopCommonModes];
}

- (void)onKeyboardWillShow:(NSNotification *)notification
{
  if (hideTimer != nil) {
    [hideTimer invalidate];
  }
  
  self.keyboardIsVisible = YES;
  
  CGRect rect = [[notification.userInfo valueForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];

  double height = rect.size.height;
    
  if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
    if (stageManagerOffset > 0) {
      height = stageManagerOffset;
    } else {
      CGRect webViewAbsolute = [self.webView convertRect:self.webView.frame toCoordinateSpace:self.webView.window.screen.coordinateSpace];
      height = (webViewAbsolute.size.height + webViewAbsolute.origin.y) - (UIScreen.mainScreen.bounds.size.height - rect.size.height);
      if (height < 0) {
        height = 0;
      }
        
      stageManagerOffset = height;
    }
  }

  // Only interfere with frame changes if not in native mode
  if (self.keyboardResizes != ResizeNative) {
    double duration = [[notification.userInfo valueForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [self setKeyboardHeight:height delay:duration];
    [self resetScrollView];
  }

  NSString * data = [NSString stringWithFormat:@"{ 'keyboardHeight': %d }", (int)height];
  [self.bridge triggerWindowJSEventWithEventName:@"keyboardWillShow" data:data];
  NSDictionary * kbData = @{@"keyboardHeight": [NSNumber numberWithDouble:height]};
  [self notifyListeners:@"keyboardWillShow" data:kbData];
}

- (void)onKeyboardDidShow:(NSNotification *)notification
{
  CGRect rect = [[notification.userInfo valueForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
  double height = rect.size.height;

  // Only interfere with scroll view if not in native mode
  if (self.keyboardResizes != ResizeNative) {
    [self resetScrollView];
  }

  NSString * data = [NSString stringWithFormat:@"{ 'keyboardHeight': %d }", (int)height];
  [self.bridge triggerWindowJSEventWithEventName:@"keyboardDidShow" data:data];
  NSDictionary * kbData = @{@"keyboardHeight": [NSNumber numberWithDouble:height]};
  [self notifyListeners:@"keyboardDidShow" data:kbData];
}

- (void)onKeyboardDidHide:(NSNotification *)notification
{
  self.keyboardIsVisible = NO;
  
  [self.bridge triggerWindowJSEventWithEventName:@"keyboardDidHide"];
  [self notifyListeners:@"keyboardDidHide" data:nil];
  
  // Only interfere with scroll view if not in native mode
  if (self.keyboardResizes != ResizeNative) {
    [self resetScrollView];
  }

  stageManagerOffset = 0;
}

- (void)setKeyboardHeight:(int)height delay:(NSTimeInterval)delay
{
  if (self.paddingBottom == height) {
    return;
  }

  self.paddingBottom = height;

  __weak KeyboardPlugin* weakSelf = self;
  SEL action = @selector(_updateFrame);
  [NSObject cancelPreviousPerformRequestsWithTarget:weakSelf selector:action object:nil];
  if (delay == 0) {
    [self _updateFrame];
  } else {
    // Use a shorter delay to ensure smooth animation
    NSTimeInterval adjustedDelay = delay > 0.1 ? delay * 0.8 : delay;
    [weakSelf performSelector:action withObject:nil afterDelay:adjustedDelay inModes:@[NSRunLoopCommonModes]];
  }
}

- (void)resizeElement:(NSString *)element withPaddingBottom:(int)paddingBottom withScreenHeight:(int)screenHeight
{
    int height = -1;
    if (paddingBottom > 0) {
        height = screenHeight - paddingBottom;
    }
    
    [self.bridge evalWithJs: [NSString stringWithFormat:@"(function() { var el = %@; var height = %d; if (el) { el.style.height = height > -1 ? height + 'px' : null; } })()", element, height]];
}

- (void)_updateFrame
{
  CGRect f, wf = CGRectZero;
  UIWindow * window = nil;
    
  if ([[[UIApplication sharedApplication] delegate] respondsToSelector:@selector(window)]) {
    window = [[[UIApplication sharedApplication] delegate] window];
  }
  
  if (!window) {
    if (@available(iOS 13.0, *)) {
      NSPredicate *predicate = [NSPredicate predicateWithFormat:@"self isKindOfClass: %@", UIWindowScene.class];
      UIScene *scene = [UIApplication.sharedApplication.connectedScenes.allObjects filteredArrayUsingPredicate:predicate].firstObject;
      window = [[(UIWindowScene*)scene windows] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isKeyWindow == YES"]].firstObject;
    }
  }
  if (window) {
    f = [window bounds];
  }
  if (self.webView != nil) {
    wf = self.webView.frame;
  }
  switch (self.keyboardResizes) {
    case ResizeBody:
    {
      [self resizeElement:@"document.body" withPaddingBottom:_paddingBottom withScreenHeight:(int)f.size.height];
      break;
    }
    case ResizeIonic:
    {
      [self resizeElement:@"document.querySelector('ion-app')" withPaddingBottom:_paddingBottom withScreenHeight:(int)f.size.height];
      break;
    }
    case ResizeNative:
    {
      // Don't interfere with native keyboard behavior - let iOS handle it naturally
      // This allows the system's smooth keyboard animations to work without plugin interference
      break;
    }
    default:
      break;
  }
  
  // Only reset scroll view if not in native mode
  if (self.keyboardResizes != ResizeNative) {
    [self resetScrollView];
  }
}


#pragma mark HideFormAccessoryBar

static IMP UIOriginalImp;
static IMP WKOriginalImp;

- (void)setHideFormAccessoryBar:(BOOL)hideFormAccessoryBar
{
  if (hideFormAccessoryBar == _hideFormAccessoryBar) {
    return;
  }
  
  // Don't modify input accessory view in native mode
  if (self.keyboardResizes == ResizeNative) {
    NSLog(@"KeyboardPlugin: In native mode, not modifying input accessory bar");
    _hideFormAccessoryBar = hideFormAccessoryBar;
    return;
  }
  
  Method UIMethod = class_getInstanceMethod(NSClassFromString(UIClassString), @selector(inputAccessoryView));
  Method WKMethod = class_getInstanceMethod(NSClassFromString(WKClassString), @selector(inputAccessoryView));
  if (hideFormAccessoryBar) {
    // Only save original implementations if not already saved
    if (UIOriginalImp == NULL && UIMethod != NULL) {
      UIOriginalImp = method_getImplementation(UIMethod);
    }
    if (WKOriginalImp == NULL && WKMethod != NULL) {
      WKOriginalImp = method_getImplementation(WKMethod);
    }
    IMP newImp = imp_implementationWithBlock(^(id _s) {
      return nil;
    });
    if (UIMethod != NULL) {
      method_setImplementation(UIMethod, newImp);
    }
    if (WKMethod != NULL) {
      method_setImplementation(WKMethod, newImp);
    }
  } else {
    // Restore original implementations if they were saved
    if (UIOriginalImp != NULL && UIMethod != NULL) {
      method_setImplementation(UIMethod, UIOriginalImp);
    }
    if (WKOriginalImp != NULL && WKMethod != NULL) {
      method_setImplementation(WKMethod, WKOriginalImp);
    }
  }
  _hideFormAccessoryBar = hideFormAccessoryBar;
}

#pragma mark scroll

- (void)setDisableScroll:(BOOL)disableScroll {
  if (disableScroll == _disableScroll) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (disableScroll) {
      self.webView.scrollView.scrollEnabled = NO;
      self.webView.scrollView.delegate = self;
    }
    else {
      self.webView.scrollView.scrollEnabled = YES;
      self.webView.scrollView.delegate = nil;
    }
  });
  _disableScroll = disableScroll;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  [scrollView setContentOffset: CGPointZero];
}

#pragma mark Plugin interface

- (void)setAccessoryBarVisible:(CAPPluginCall *)call
{
  BOOL value = [call getBool:@"isVisible" defaultValue:FALSE];

  NSLog(@"Accessory bar visible change %d", value);
  self.hideFormAccessoryBar = !value;
  [call resolve];
}

- (void)hide:(CAPPluginCall *)call
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.webView endEditing:YES];
  });
  [call resolve];
}

- (void)show:(CAPPluginCall *)call
{
  [call unimplemented];
}

- (void)setStyle:(CAPPluginCall *)call
{
  self.keyboardStyle = [call getString:@"style" defaultValue:@"LIGHT"];
  [self changeKeyboardStyle:self.keyboardStyle]; 
  [call resolve];
}

- (void)setResizeMode:(CAPPluginCall *)call
{
  NSString * mode = [call getString:@"mode" defaultValue:@"none"];
  ResizePolicy previousMode = self.keyboardResizes;
  
  NSLog(@"KeyboardPlugin: Changing resize mode from %@ to %@", 
        previousMode == ResizeNative ? @"native" : 
        previousMode == ResizeNone ? @"none" :
        previousMode == ResizeBody ? @"body" : @"ionic",
        mode);
  
  if ([mode isEqualToString:@"ionic"]) {
    self.keyboardResizes = ResizeIonic;
  } else if ([mode isEqualToString:@"body"]) {
    self.keyboardResizes = ResizeBody;
  } else if ([mode isEqualToString:@"native"]) {
    self.keyboardResizes = ResizeNative;
  } else {
    self.keyboardResizes = ResizeNone;
  }
  
  // Reset plugin state when switching modes, especially when switching to/from native
  if (previousMode != self.keyboardResizes) {
    NSLog(@"KeyboardPlugin: Mode changed, resetting plugin state");
    [self resetPluginState];
    
    // Handle keyboard observer registration based on new mode
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    if (self.keyboardResizes == ResizeNative) {
      // Switching TO native mode - unregister our observers and let WebView handle naturally
      NSLog(@"KeyboardPlugin: Switching to native mode - unregistering keyboard observers");
      [nc removeObserver:self name:UIKeyboardDidHideNotification object:nil];
      [nc removeObserver:self name:UIKeyboardDidShowNotification object:nil];
      [nc removeObserver:self name:UIKeyboardWillHideNotification object:nil];
      [nc removeObserver:self name:UIKeyboardWillShowNotification object:nil];
      
      // Restore WebView to completely natural state
      [self restoreWebViewToNaturalState];
    } else if (previousMode == ResizeNative) {
      // Switching FROM native mode - register our observers
      NSLog(@"KeyboardPlugin: Switching from native mode - registering keyboard observers");
      [nc addObserver:self selector:@selector(onKeyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];
      [nc addObserver:self selector:@selector(onKeyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];
      [nc addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
      [nc addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
      
      [nc removeObserver:self.webView name:UIKeyboardWillHideNotification object:nil];
      [nc removeObserver:self.webView name:UIKeyboardWillShowNotification object:nil];
      [nc removeObserver:self.webView name:UIKeyboardWillChangeFrameNotification object:nil];
      [nc removeObserver:self.webView name:UIKeyboardDidChangeFrameNotification object:nil];
    }
  } else {
    NSLog(@"KeyboardPlugin: Mode unchanged, no reset needed");
  }
  
  [call resolve];
}

- (void)getResizeMode:(CAPPluginCall *)call
{
    NSString *mode;
    
    if (self.keyboardResizes == ResizeIonic) {
        mode = @"ionic";
    } else if(self.keyboardResizes == ResizeBody) {
        mode = @"body";
    } else if (self.keyboardResizes == ResizeNative) {
        mode = @"native";
    } else {
        mode = @"none";
    }
    
    NSDictionary *response = [NSDictionary dictionaryWithObject:mode forKey:@"mode"];
    [call resolve: response];
}

- (void)setScroll:(CAPPluginCall *)call {
  self.disableScroll = [call getBool:@"isDisabled" defaultValue:FALSE];
  [call resolve];
}

- (void)changeKeyboardStyle:(NSString*)style
{
  IMP newImp = nil;
  if ([style isEqualToString:@"DARK"]) {
    newImp = imp_implementationWithBlock(^(id _s) {
      return UIKeyboardAppearanceDark;
    });
  } else if ([style isEqualToString:@"LIGHT"]) {
    newImp = imp_implementationWithBlock(^(id _s) {
      return UIKeyboardAppearanceLight;
    });
  } else {
    newImp = imp_implementationWithBlock(^(id _s) {
      return UIKeyboardAppearanceDefault;
    });
  }
  for (NSString* classString in @[WKClassString, UITraitsClassString]) {
    Class c = NSClassFromString(classString);
    Method m = class_getInstanceMethod(c, @selector(keyboardAppearance));
    if (m != NULL) {
      method_setImplementation(m, newImp);
    } else {
      class_addMethod(c, @selector(keyboardAppearance), newImp, "l@:");
    }
  }
  _keyboardStyle = style;
}

#pragma mark dealloc

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
#pragma clang diagnostic pop


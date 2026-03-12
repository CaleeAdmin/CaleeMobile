#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
// Expose Swift types (including CalendarHostApiImpl and NativeCalendarApiSetup) to Objective-C.
#import "Runner-Swift.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [GeneratedPluginRegistrant registerWithRegistry:self];
  // Override point for customization after application launch.

  // Register our Calendar API implemented in Swift
  CalendarHostApiImpl *calendarApi = [[CalendarHostApiImpl alloc] init];
  [NativeCalendarApiSetup setUpWithBinaryMessenger:self.binaryMessenger api:calendarApi];

  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

@end

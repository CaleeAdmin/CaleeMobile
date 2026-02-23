#import "AppDelegate.h"
#import "GeneratedPluginRegistrant.h"
#import "CalendarHostApiImpl.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [GeneratedPluginRegistrant registerWithRegistry:self];
  // Override point for customization after application launch.

  // Register our Calendar API
  CalendarHostApiImpl *calendarApi = [[CalendarHostApiImpl alloc] init];
  [NativeCalendarApiSetup setUpWithBinaryMessenger:self.binaryMessenger api:calendarApi];

  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

@end

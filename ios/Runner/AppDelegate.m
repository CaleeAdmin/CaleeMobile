#import "AppDelegate.h"
#import "Runner-Swift.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  // Swift AppDelegate owns plugin registration and Pigeon setup. Keep the
  // Objective-C shim free of duplicate GeneratedPluginRegistrant calls.
  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

@end

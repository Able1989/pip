//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

#if __has_include(<integration_test/IntegrationTestPlugin.h>)
#import <integration_test/IntegrationTestPlugin.h>
#else
@import integration_test;
#endif

#if __has_include(<native_plugin/NativePlugin.h>)
#import <native_plugin/NativePlugin.h>
#else
@import native_plugin;
#endif

#if __has_include(<pip/PipPlugin.h>)
#import <pip/PipPlugin.h>
#else
@import pip;
#endif

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
  [IntegrationTestPlugin registerWithRegistrar:[registry registrarForPlugin:@"IntegrationTestPlugin"]];
  [NativePlugin registerWithRegistrar:[registry registrarForPlugin:@"NativePlugin"]];
  [PipPlugin registerWithRegistrar:[registry registrarForPlugin:@"PipPlugin"]];
}

@end

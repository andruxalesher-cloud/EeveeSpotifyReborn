"""Run the actual hook/URI helpers against a small macOS Objective-C runtime fixture."""
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).with_name("ExternalDownloads.m").read_text()


def function(signature):
    start = source.index(signature)
    end = source.index("\n}\n", start) + 3
    return source[start:end]


harness = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <assert.h>
static NSMutableDictionary<NSString *, NSValue *> *EDInstalledHooks;
typedef void (^EDReply)(id);
static id capturedResponse;
static void EDCaptureResponse(id response) { capturedResponse = response; }
@interface Fixture : NSObject
- (NSInteger)value;
@end
@implementation Fixture
- (NSInteger)value { return 7; }
@end
@interface Child : Fixture
@end
@implementation Child
@end
'''
harness += function("static BOOL EDIsCollection(")
harness += function("static void EDHook(")
harness += function("static id EDCapturedReply(")
harness += function("static id EDCapturedViewReply(")
harness += function("static id EDCapturedRecommendationsReply(")
harness += r'''
int main(void) {
    @autoreleasepool {
        assert(EDIsCollection(@"spotify:collection"));
        assert(EDIsCollection(@"spotify:collection:tracks"));
        assert(EDIsCollection(@"spotify:user:example:collection"));
        assert(!EDIsCollection(@"spotify:album:example"));
        assert(!EDIsCollection(nil));
        Class cls = Child.class;
        SEL sel = @selector(value);
        IMP original = class_getMethodImplementation(cls, sel);
        EDHook(cls, @"value", ^NSInteger(id object) {
            return ((NSInteger (*)(id, SEL))original)(object, sel) + 1;
        });
        assert([[Child new] value] == 8);
        assert([[Fixture new] value] == 7); // Never replace an inherited superclass method.
        IMP installed = class_getMethodImplementation(cls, sel);
        EDHook(cls, @"value", ^NSInteger(id object) { return 99; });
        assert(class_getMethodImplementation(cls, sel) == installed);
        assert([[Child new] value] == 8); // Foreground/launch retries do not nest hooks.
        class_replaceMethod(cls, sel, original, "q@:");
        EDHook(cls, @"value", ^NSInteger(id object) { return 100; });
        assert([[Child new] value] == 8); // Restore after a later initialization overwrites it.
        EDHook(Nil, @"value", ^NSInteger(id object) { return 0; });
        EDHook(cls, @"missingSelector", ^NSInteger(id object) { return 0; });
        __block BOOL called = NO;
        void (^single)(id) = EDCapturedReply(^(id tracks) { assert([tracks isEqual:@"tracks"]); called = YES; });
        single(@"tracks"); assert(called && [capturedResponse isEqual:@"tracks"]);
        called = NO;
        void (^view)(id, id) = EDCapturedViewReply(^(id metadata, id tracks) {
            assert([metadata isEqual:@"metadata"] && [tracks isEqual:@"tracks"]); called = YES;
        });
        view(@"metadata", @"tracks"); assert(called && [capturedResponse isEqual:@"tracks"]);
        called = NO;
        void (^recommendations)(id, id, id) = EDCapturedRecommendationsReply(^(id metadata, id tracks, id extra) {
            assert([metadata isEqual:@"metadata"] && [tracks isEqual:@"tracks"] && [extra isEqual:@"extra"]); called = YES;
        });
        recommendations(@"metadata", @"tracks", @"extra"); assert(called && [capturedResponse isEqual:@"tracks"]);
        assert(EDCapturedReply(nil) == nil && EDCapturedViewReply(nil) == nil && EDCapturedRecommendationsReply(nil) == nil);
        puts("PASS: collection routes, hook retries, late replacement, inherited methods, missing classes");
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    program = Path(directory) / "runtime_helpers.m"
    binary = Path(directory) / "runtime_helpers"
    program.write_text(harness)
    subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", str(program), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

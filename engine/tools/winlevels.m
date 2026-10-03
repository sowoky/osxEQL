// From EQBuddy 1.99.18 scripts/crossover/winlevels.m — MIT License,
// Copyright (c) 2026 David Edwards (see THIRD-PARTY-NOTICES.md).
// Built on demand by `osxeql winlevels`.
// winlevels — native macOS window-level inspector (public API only, no SIP, no Wine).
// Reports every on-screen window's owner, title, and CoreGraphics window LEVEL.
// Run it while EQL is fullscreen + EQBuddy is up to measure the real z-order:
// this turns the "game sits at level 26, widget at 21" claim from inference
// into a number you can see. kCGWindowLayer in the window-list dictionary IS
// the CG window level (signed).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *filter = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : nil;

        CFArrayRef windows = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);
        if (!windows) { fprintf(stderr, "CGWindowListCopyWindowInfo returned NULL\n"); return 1; }

        printf("%-6s  %-26s  %-9s  %s\n", "LEVEL", "OWNER", "WINDOW#", "TITLE");
        printf("%-6s  %-26s  %-9s  %s\n", "-----", "--------------------------", "-------", "-----");

        CFIndex n = CFArrayGetCount(windows);
        for (CFIndex i = 0; i < n; i++) {
            NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windows, i);
            NSNumber *layer = w[(__bridge NSString *)kCGWindowLayer];
            NSString *owner = w[(__bridge NSString *)kCGWindowOwnerName] ?: @"(none)";
            NSString *title = w[(__bridge NSString *)kCGWindowName] ?: @"";
            NSNumber *num   = w[(__bridge NSString *)kCGWindowNumber];

            if (filter && [owner rangeOfString:filter options:NSCaseInsensitiveSearch].location == NSNotFound
                       && [title rangeOfString:filter options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;

            printf("%-6ld  %-26.26s  %-9ld  %.60s\n",
                   (long)[layer integerValue],
                   [owner UTF8String],
                   (long)[num integerValue],
                   [title UTF8String]);
        }
        CFRelease(windows);

        printf("\nReference levels: Normal=0  Dock=20  MainMenu=24  Status=25  "
               "Floating=3  PopUpMenu=101  Shield=CGShieldingWindowLevel()=%d\n",
               CGShieldingWindowLevel());
        printf("Tip: `winlevels EQ` filters to EverQuest/EQBuddy rows.\n");
    }
    return 0;
}

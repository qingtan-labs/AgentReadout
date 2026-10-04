#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 64;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            [@(argv[1]) stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *zip = @(argv[2]);
        NSData *data = [NSData dataWithContentsOfFile:zip];
        if (!info || !data) return 65;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *sha = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [sha appendFormat:@"%02x", digest[i]];
        NSDictionary *manifest = @{@"version": info[@"CFBundleShortVersionString"],
            @"build": info[@"CFBundleVersion"], @"bundleIdentifier": info[@"CFBundleIdentifier"],
            @"archive": zip.lastPathComponent, @"sha256": sha};
        NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        return [json writeToFile:[zip.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"update.json"] atomically:YES] ? 0 : 66;
    }
}

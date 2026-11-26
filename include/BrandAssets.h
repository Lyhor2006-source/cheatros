#pragma once

#include <cstdint>
#include <cstddef>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

// Bundled UI assets packaged for the standalone iOS overlay dylib:
//   - assets/brand_texture.png         : 318,347 bytes (0x4db8b), 640x640 RGBA PNG
//   - assets/primary_font.ttf          : 162,588 bytes (0x27b1c), Roboto Medium v2.001152 (2014)
//   - assets/fontawesome_compressed.bin: 124,565 bytes (0x1e695), stb_compress FontAwesome (uncompressed 165,548 bytes)

namespace BrandAssets {

extern const unsigned char kBrandTexturePngData[];
extern const size_t kBrandTexturePngSize;
extern const unsigned char kPrimaryFontTtfData[];
extern const size_t kPrimaryFontTtfSize;
extern const unsigned char kFontAwesomeBinData[];
extern const size_t kFontAwesomeBinSize;

inline constexpr const uint16_t kFontAwesomeGlyphRanges[] = {
    0xF000, 0xFFF8,
    0
};

#ifdef __OBJC__
inline NSData* LoadAssetData(NSString* filename) {
    if (!filename.length) return nil;

    // 1. Check `<AppBundle>/assets/<filename>`
    NSString* bundlePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"assets"];
    NSString* candidate = [bundlePath stringByAppendingPathComponent:filename];
    NSData* data = [NSData dataWithContentsOfFile:candidate];
    if (data) return data;

    // 2. Check `<AppBundle>/<filename>`
    candidate = [[NSBundle mainBundle] pathForResource:filename ofType:nil];
    if (candidate) {
        data = [NSData dataWithContentsOfFile:candidate];
        if (data) return data;
    }

    // 3. Check `Documents/assets/<filename>`
    NSArray<NSString*>* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count > 0) {
        candidate = [[docs.firstObject stringByAppendingPathComponent:@"assets"] stringByAppendingPathComponent:filename];
        data = [NSData dataWithContentsOfFile:candidate];
        if (data) return data;
    }

    // 4. Fallback to bytes compiled directly inside RosModV2UI.dylib
    if ([filename isEqualToString:@"brand_texture.png"]) {
        return [NSData dataWithBytesNoCopy:const_cast<unsigned char*>(kBrandTexturePngData)
                                    length:kBrandTexturePngSize
                              freeWhenDone:NO];
    }
    if ([filename isEqualToString:@"primary_font.ttf"]) {
        return [NSData dataWithBytesNoCopy:const_cast<unsigned char*>(kPrimaryFontTtfData)
                                    length:kPrimaryFontTtfSize
                              freeWhenDone:NO];
    }
    if ([filename isEqualToString:@"fontawesome_compressed.bin"]) {
        return [NSData dataWithBytesNoCopy:const_cast<unsigned char*>(kFontAwesomeBinData)
                                    length:kFontAwesomeBinSize
                              freeWhenDone:NO];
    }

    return nil;
}
#endif

} // namespace BrandAssets

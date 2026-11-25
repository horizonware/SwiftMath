
import Foundation
import CoreText

//
//  Created by Mike Griebling on 2022-12-31.
//  Translated from an Objective-C implementation by Kostub Deshmukh.
//
//  This software may be modified and distributed under the terms of the
//  MIT license. See the LICENSE file for details.
//

public class MTFont {
    
    var defaultCGFont: CGFont!
    var ctFont: CTFont!
    var mathTable: MTFontMathTable?
    var rawMathTable: NSDictionary?
    
    init() {}
    
    /// `MTFont(fontWithName:)` does not load the complete math font, it only has about half the glyphs of the full math font.
    /// In particular it does not have the math italic characters which breaks our variable rendering.
    /// So we first load a CGFont from the file and then convert it to a CTFont.
    convenience init(fontWithName name: String, size:CGFloat) {
        self.init()
        //print("Loading font \(name)")
        let bundle = MTFont.fontBundle
        let fontPath = bundle.path(forResource: name, ofType: "otf")
        let fontDataProvider = CGDataProvider(filename: fontPath!)
        self.defaultCGFont = CGFont(fontDataProvider!)!
        //print("Num glyphs: \(self.defaultCGFont.numberOfGlyphs)")
        
        self.ctFont = CTFontCreateWithGraphicsFont(self.defaultCGFont, size, nil, nil);
        
        //print("Loading associated .plist")
        let mathTablePlist = bundle.url(forResource:name, withExtension:"plist")
        self.rawMathTable = NSDictionary(contentsOf: mathTablePlist!)
        self.mathTable = MTFontMathTable(withFont:self, mathTable:rawMathTable!)
    }
    
    static var fontBundle:Bundle {
        // Uses bundle for class so that this can be access by the unit tests.
        Bundle(url: Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")!)!
    }
    
    /** Returns a copy of this font but with a different size. */
    public func copy(withSize size: CGFloat) -> MTFont {
        // MathWright fork patch (1.7.3-mathwright.6): the typesetter copies the font on every style and
        // script change, and each copy made a new CTFont and math table (about 28% of typesetting). An
        // MTFont is never changed after it is built - its properties are set only here and in its
        // initialisers - so copies of one font at one size are shared. The key holds the CGFont and the raw
        // math table by identity; the cached copy retains both, so neither identity can be reused while
        // its entry lives. Guarded by a lock (typesetting runs on any thread) and capped.
        let key = SizeKey(cgFont: ObjectIdentifier(defaultCGFont),
                          mathTable: rawMathTable.map { ObjectIdentifier($0) }, size: size)
        MTFont.sizeCacheLock.lock()
        defer { MTFont.sizeCacheLock.unlock() }
        if let shared = MTFont.sizeCache[key] { return shared }
        let newFont = MTFont()
        newFont.defaultCGFont = self.defaultCGFont
        newFont.ctFont = CTFontCreateWithGraphicsFont(self.defaultCGFont, size, nil, nil)
        newFont.rawMathTable = self.rawMathTable
        newFont.mathTable = MTFontMathTable(withFont: newFont, mathTable: newFont.rawMathTable!)
        if MTFont.sizeCache.count >= MTFont.sizeCacheLimit { MTFont.sizeCache.removeAll(keepingCapacity: true) }
        MTFont.sizeCache[key] = newFont
        return newFont
    }

    private struct SizeKey: Hashable {
        let cgFont: ObjectIdentifier
        let mathTable: ObjectIdentifier?
        let size: CGFloat
    }

    private static let sizeCacheLock = NSLock()
    private static var sizeCache: [SizeKey: MTFont] = [:]
    private static let sizeCacheLimit = 256
    
    func get(nameForGlyph glyph:CGGlyph) -> String {
        let name = defaultCGFont.name(for: glyph) as? String
        return name ?? ""
    }
    
    func get(glyphWithName name:String) -> CGGlyph {
        GlyphNameMemo.memo(for: defaultCGFont).glyph(named: name, in: defaultCGFont)
    }

    // MathWright fork patch (1.7.3-mathwright.7): `CGFontGetGlyphWithGlyphName` searches the font's glyph-name
    // table on every call (about 7% of a maths-heavy first layout, mostly from `getVariantsForGlyph`, whose V2 path
    // builds a fresh MTFontV2 per call). A glyph's name never changes for one CGFont, so answers are kept per CGFont.
    // The table holds each CGFont strongly, so its identity cannot be reused while its entry lives; each memo has its
    // own lock (fonts loaded per thread never contend on it), the table lock is held only for the lookup. Capped.
    final class GlyphNameMemo {
        private let lock = NSLock()
        private var glyphs: [String: CGGlyph] = [:]

        func glyph(named name: String, in font: CGFont) -> CGGlyph {
            lock.lock()
            if let hit = glyphs[name] { lock.unlock(); return hit }
            lock.unlock()
            let glyph = font.getGlyphWithGlyphName(name: name as CFString)
            lock.lock(); glyphs[name] = glyph; lock.unlock()
            return glyph
        }

        private static let tableLock = NSLock()
        private static var table: [ObjectIdentifier: (font: CGFont, memo: GlyphNameMemo)] = [:]
        private static let tableLimit = 64

        static func memo(for font: CGFont) -> GlyphNameMemo {
            let key = ObjectIdentifier(font)
            tableLock.lock()
            defer { tableLock.unlock() }
            if let entry = table[key] { return entry.memo }
            if table.count >= tableLimit { table.removeAll(keepingCapacity: true) }
            let memo = GlyphNameMemo()
            table[key] = (font, memo)
            return memo
        }
    }
    
    /** The size of this font in points. */
    public var fontSize:CGFloat { CTFontGetSize(self.ctFont) }
    
    deinit {
        self.ctFont = nil
        self.defaultCGFont = nil
    }
    
}

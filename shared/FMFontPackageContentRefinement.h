#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Selection reason code recorded on the refined match entry and in the
// "contentSelection" summary when the winner was chosen by content probe.
FOUNDATION_EXPORT NSString *const
    FMFontContentSelectionReasonLegacyChinesePunctuationCompact;

// Content-based refinement for the legacy Chinese Stock target
// (LanguageSupport/PingFang.ttc, iOS 16-17 layouts). Community packages often
// ship several PingFang repacks under different filenames (for example
// "PingFang.ttc" and an "iOS17专用PingFang.ttc" variant with compressed
// punctuation metrics). The filename matcher keeps reporting only the exact
// stock-name file; this refinement promotes probe-qualified package sources
// into candidates for the same target and deterministically selects the one
// whose PingFangSC-Regular fullwidth comma (U+FF0C) advance is smallest, so
// the punctuation-tuned variant wins without adding any user choice.
//
// The refinement never modifies font bytes: it only chooses which package
// source is recorded as the replacement. PingFang.ttc and PingFangUI.ttc
// remain distinct targets; sources belonging to the other system layout stay
// ignored, and a target with a filename conflict is left untouched.

// Relative paths whose font content must be probed before refinement can
// decide: every unmatched source plus the exact-name source currently matched
// to the legacy Chinese target, but only when the catalog offers that target
// (legacy layout, no PingFangUI.ttc target) and the target has no conflict.
// Returns an empty array when nothing has to be probed, which is the common
// case for packages whose files all match by filename.
NSArray<NSString *> *FMContentSelectionProbeRelativePaths(
    NSDictionary<NSString *, id> *matching,
    NSDictionary<NSString *, id> *catalog);

// Content probe for one package font file. Reports whether the data contains
// a face with PostScript name "PingFangSC-Regular" and, when it does, that
// face's fullwidth comma (U+FF0C) advance ratio in em units. A missing comma
// glyph is reported as ratio 1.0 so the face stays eligible but ranks last.
// Returns nil when CoreText cannot produce font descriptors for the data.
NSDictionary<NSString *, id> * _Nullable FMProbeFontDataForContentSelection(
    NSData *fontData);

// Applies the probe results to a filename-matching result. Candidates are the
// exact-name source already matched to the legacy Chinese target plus every
// unmatched source whose probe reports the PingFangSC-Regular face; the
// smallest comma ratio wins, ties prefer the exact stock filename and then
// the lexicographically smallest path. When the winner is the already matched
// source, or the catalog has no legacy Chinese target, or that target has a
// conflict, the input dictionary is returned unchanged. Otherwise the return
// is a rebuilt matching document: the selected source replaces the target's
// match entry (with a selectionReason code), displaced sources move to
// "unmatched", counts stay consistent, and a top-level "contentSelection"
// summary records every candidate and its comma ratio.
NSDictionary<NSString *, id> *FMRefineLegacyChineseTargetSelection(
    NSDictionary<NSString *, id> *matching,
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *probesByPath,
    NSDictionary<NSString *, id> *catalog);

NS_ASSUME_NONNULL_END

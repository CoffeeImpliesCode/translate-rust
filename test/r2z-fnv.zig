// Golden emitter output for the fnv crate (P2 target).
// FNV-1a hash: one public const fn over a byte slice, no allocation,
// no generics, no traits — the simplest possible translation target.

const std = @import("std");

pub const FNV_OFFSET_BASIS: u64 = 14695981039346656037;
pub const FNV_PRIME: u64 = 1099511628211;
pub fn fnv1a_hash(data: []const u8) u64 {
    var h: u64 = FNV_OFFSET_BASIS;
    for (data) |byte| {
        h ^= byte;
        h *%= FNV_PRIME;
    }
    return h;
}

test "basic_tests" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a_hash(""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a_hash("a"));
    try std.testing.expectEqual(@as(u64, 0xaf63df4c8601f1a5), fnv1a_hash("b"));
    try std.testing.expectEqual(@as(u64, 0xaf63de4c8601eff2), fnv1a_hash("c"));
    try std.testing.expectEqual(@as(u64, 0xaf63d94c8601e773), fnv1a_hash("d"));
    try std.testing.expectEqual(@as(u64, 0xaf63d84c8601e5c0), fnv1a_hash("e"));
    try std.testing.expectEqual(@as(u64, 0xaf63db4c8601ead9), fnv1a_hash("f"));
    try std.testing.expectEqual(@as(u64, 0x08985907b541d342), fnv1a_hash("fo"));
    try std.testing.expectEqual(@as(u64, 0xdcb27518fed9d577), fnv1a_hash("foo"));
    try std.testing.expectEqual(@as(u64, 0xdd120e790c2512af), fnv1a_hash("foob"));
    try std.testing.expectEqual(@as(u64, 0xcac165afa2fef40a), fnv1a_hash("fooba"));
    try std.testing.expectEqual(@as(u64, 0x85944171f73967e8), fnv1a_hash("foobar"));
    try std.testing.expectEqual(@as(u64, 0xaf63bd4c8601b7df), fnv1a_hash("\x00"));
    try std.testing.expectEqual(@as(u64, 0x089be207b544f1e4), fnv1a_hash("a\x00"));
    try std.testing.expectEqual(@as(u64, 0x08a61407b54d9b5f), fnv1a_hash("b\x00"));
    try std.testing.expectEqual(@as(u64, 0x08a2ae07b54ab836), fnv1a_hash("c\x00"));
    try std.testing.expectEqual(@as(u64, 0x0891b007b53c4869), fnv1a_hash("d\x00"));
    try std.testing.expectEqual(@as(u64, 0x088e4a07b5396540), fnv1a_hash("e\x00"));
    try std.testing.expectEqual(@as(u64, 0x08987c07b5420ebb), fnv1a_hash("f\x00"));
    try std.testing.expectEqual(@as(u64, 0xdcb28a18fed9f926), fnv1a_hash("fo\x00"));
    try std.testing.expectEqual(@as(u64, 0xdd1270790c25b935), fnv1a_hash("foo\x00"));
    try std.testing.expectEqual(@as(u64, 0xcac146afa2febf5d), fnv1a_hash("foob\x00"));
    try std.testing.expectEqual(@as(u64, 0x8593d371f738acfe), fnv1a_hash("fooba\x00"));
    try std.testing.expectEqual(@as(u64, 0x34531ca7168b8f38), fnv1a_hash("foobar\x00"));
    try std.testing.expectEqual(@as(u64, 0x08a25607b54a22ae), fnv1a_hash("ch"));
    try std.testing.expectEqual(@as(u64, 0xf5faf0190cf90df3), fnv1a_hash("cho"));
    try std.testing.expectEqual(@as(u64, 0xf27397910b3221c7), fnv1a_hash("chon"));
    try std.testing.expectEqual(@as(u64, 0x2c8c2b76062f22e0), fnv1a_hash("chong"));
    try std.testing.expectEqual(@as(u64, 0xe150688c8217b8fd), fnv1a_hash("chongo"));
    try std.testing.expectEqual(@as(u64, 0xf35a83c10e4f1f87), fnv1a_hash("chongo "));
    try std.testing.expectEqual(@as(u64, 0xd1edd10b507344d0), fnv1a_hash("chongo w"));
    try std.testing.expectEqual(@as(u64, 0x2a5ee739b3ddb8c3), fnv1a_hash("chongo wa"));
    try std.testing.expectEqual(@as(u64, 0xdcfb970ca1c0d310), fnv1a_hash("chongo was"));
    try std.testing.expectEqual(@as(u64, 0x4054da76daa6da90), fnv1a_hash("chongo was "));
    try std.testing.expectEqual(@as(u64, 0xf70a2ff589861368), fnv1a_hash("chongo was h"));
    try std.testing.expectEqual(@as(u64, 0x4c628b38aed25f17), fnv1a_hash("chongo was he"));
    try std.testing.expectEqual(@as(u64, 0x9dd1f6510f78189f), fnv1a_hash("chongo was her"));
    try std.testing.expectEqual(@as(u64, 0xa3de85bd491270ce), fnv1a_hash("chongo was here"));
    try std.testing.expectEqual(@as(u64, 0x858e2fa32a55e61d), fnv1a_hash("chongo was here!"));
    try std.testing.expectEqual(@as(u64, 0x46810940eff5f915), fnv1a_hash("chongo was here!\n"));
    try std.testing.expectEqual(@as(u64, 0xf5fadd190cf8edaa), fnv1a_hash("ch\x00"));
    try std.testing.expectEqual(@as(u64, 0xf273ed910b32b3e9), fnv1a_hash("cho\x00"));
    try std.testing.expectEqual(@as(u64, 0x2c8c5276062f6525), fnv1a_hash("chon\x00"));
    try std.testing.expectEqual(@as(u64, 0xe150b98c821842a0), fnv1a_hash("chong\x00"));
    try std.testing.expectEqual(@as(u64, 0xf35aa3c10e4f55e7), fnv1a_hash("chongo\x00"));
    try std.testing.expectEqual(@as(u64, 0xd1ed680b50729265), fnv1a_hash("chongo \x00"));
    try std.testing.expectEqual(@as(u64, 0x2a5f0639b3dded70), fnv1a_hash("chongo w\x00"));
    try std.testing.expectEqual(@as(u64, 0xdcfbaa0ca1c0f359), fnv1a_hash("chongo wa\x00"));
    try std.testing.expectEqual(@as(u64, 0x4054ba76daa6a430), fnv1a_hash("chongo was\x00"));
    try std.testing.expectEqual(@as(u64, 0xf709c7f5898562b0), fnv1a_hash("chongo was \x00"));
    try std.testing.expectEqual(@as(u64, 0x4c62e638aed2f9b8), fnv1a_hash("chongo was h\x00"));
    try std.testing.expectEqual(@as(u64, 0x9dd1a8510f779415), fnv1a_hash("chongo was he\x00"));
    try std.testing.expectEqual(@as(u64, 0xa3de2abd4911d62d), fnv1a_hash("chongo was her\x00"));
    try std.testing.expectEqual(@as(u64, 0x858e0ea32a55ae0a), fnv1a_hash("chongo was here\x00"));
    try std.testing.expectEqual(@as(u64, 0x46810f40eff60347), fnv1a_hash("chongo was here!\x00"));
    try std.testing.expectEqual(@as(u64, 0xc33bce57bef63eaf), fnv1a_hash("chongo was here!\n\x00"));
    try std.testing.expectEqual(@as(u64, 0x08a24307b54a0265), fnv1a_hash("cu"));
    try std.testing.expectEqual(@as(u64, 0xf5b9fd190cc18d15), fnv1a_hash("cur"));
    try std.testing.expectEqual(@as(u64, 0x4c968290ace35703), fnv1a_hash("curd"));
    try std.testing.expectEqual(@as(u64, 0x07174bd5c64d9350), fnv1a_hash("curds"));
    try std.testing.expectEqual(@as(u64, 0x5a294c3ff5d18750), fnv1a_hash("curds "));
    try std.testing.expectEqual(@as(u64, 0x05b3c1aeb308b843), fnv1a_hash("curds a"));
    try std.testing.expectEqual(@as(u64, 0xb92a48da37d0f477), fnv1a_hash("curds an"));
    try std.testing.expectEqual(@as(u64, 0x73cdddccd80ebc49), fnv1a_hash("curds and"));
    try std.testing.expectEqual(@as(u64, 0xd58c4c13210a266b), fnv1a_hash("curds and "));
    try std.testing.expectEqual(@as(u64, 0xe78b6081243ec194), fnv1a_hash("curds and w"));
    try std.testing.expectEqual(@as(u64, 0xb096f77096a39f34), fnv1a_hash("curds and wh"));
    try std.testing.expectEqual(@as(u64, 0xb425c54ff807b6a3), fnv1a_hash("curds and whe"));
    try std.testing.expectEqual(@as(u64, 0x23e520e2751bb46e), fnv1a_hash("curds and whey"));
    try std.testing.expectEqual(@as(u64, 0x1a0b44ccfe1385ec), fnv1a_hash("curds and whey\n"));
    try std.testing.expectEqual(@as(u64, 0xf5ba4b190cc2119f), fnv1a_hash("cu\x00"));
    try std.testing.expectEqual(@as(u64, 0x4c962690ace2baaf), fnv1a_hash("cur\x00"));
    try std.testing.expectEqual(@as(u64, 0x0716ded5c64cda19), fnv1a_hash("curd\x00"));
    try std.testing.expectEqual(@as(u64, 0x5a292c3ff5d150f0), fnv1a_hash("curds\x00"));
    try std.testing.expectEqual(@as(u64, 0x05b3e0aeb308ecf0), fnv1a_hash("curds \x00"));
    try std.testing.expectEqual(@as(u64, 0xb92a5eda37d119d9), fnv1a_hash("curds a\x00"));
    try std.testing.expectEqual(@as(u64, 0x73ce41ccd80f6635), fnv1a_hash("curds an\x00"));
    try std.testing.expectEqual(@as(u64, 0xd58c2c132109f00b), fnv1a_hash("curds and\x00"));
    try std.testing.expectEqual(@as(u64, 0xe78baf81243f47d1), fnv1a_hash("curds and \x00"));
    try std.testing.expectEqual(@as(u64, 0xb0968f7096a2ee7c), fnv1a_hash("curds and w\x00"));
    try std.testing.expectEqual(@as(u64, 0xb425a84ff807855c), fnv1a_hash("curds and wh\x00"));
    try std.testing.expectEqual(@as(u64, 0x23e4e9e2751b56f9), fnv1a_hash("curds and whe\x00"));
    try std.testing.expectEqual(@as(u64, 0x1a0b4eccfe1396ea), fnv1a_hash("curds and whey\x00"));
    try std.testing.expectEqual(@as(u64, 0x54abd453bb2c9004), fnv1a_hash("curds and whey\n\x00"));
    try std.testing.expectEqual(@as(u64, 0x08ba5f07b55ec3da), fnv1a_hash("hi"));
    try std.testing.expectEqual(@as(u64, 0x337354193006cb6e), fnv1a_hash("hi\x00"));
    try std.testing.expectEqual(@as(u64, 0xa430d84680aabd0b), fnv1a_hash("hello"));
    try std.testing.expectEqual(@as(u64, 0xa9bc8acca21f39b1), fnv1a_hash("hello\x00"));
    try std.testing.expectEqual(@as(u64, 0x6961196491cc682d), fnv1a_hash(&[_]u8{ 0xff, 0x00, 0x00, 0x01 }));
    try std.testing.expectEqual(@as(u64, 0xad2bb1774799dfe9), fnv1a_hash(&[_]u8{ 0x01, 0x00, 0x00, 0xff }));
    try std.testing.expectEqual(@as(u64, 0x6961166491cc6314), fnv1a_hash(&[_]u8{ 0xff, 0x00, 0x00, 0x02 }));
    try std.testing.expectEqual(@as(u64, 0x8d1bb3904a3b1236), fnv1a_hash(&[_]u8{ 0x02, 0x00, 0x00, 0xff }));
    try std.testing.expectEqual(@as(u64, 0x6961176491cc64c7), fnv1a_hash(&[_]u8{ 0xff, 0x00, 0x00, 0x03 }));
    try std.testing.expectEqual(@as(u64, 0xed205d87f40434c7), fnv1a_hash(&[_]u8{ 0x03, 0x00, 0x00, 0xff }));
    try std.testing.expectEqual(@as(u64, 0x6961146491cc5fae), fnv1a_hash(&[_]u8{ 0xff, 0x00, 0x00, 0x04 }));
    try std.testing.expectEqual(@as(u64, 0xcd3baf5e44f8ad9c), fnv1a_hash(&[_]u8{ 0x04, 0x00, 0x00, 0xff }));
    try std.testing.expectEqual(@as(u64, 0xe3b36596127cd6d8), fnv1a_hash(&[_]u8{ 0x40, 0x51, 0x4e, 0x44 }));
    try std.testing.expectEqual(@as(u64, 0xf77f1072c8e8a646), fnv1a_hash(&[_]u8{ 0x44, 0x4e, 0x51, 0x40 }));
    try std.testing.expectEqual(@as(u64, 0xe3b36396127cd372), fnv1a_hash(&[_]u8{ 0x40, 0x51, 0x4e, 0x4a }));
    try std.testing.expectEqual(@as(u64, 0x6067dce9932ad458), fnv1a_hash(&[_]u8{ 0x4a, 0x4e, 0x51, 0x40 }));
    try std.testing.expectEqual(@as(u64, 0xe3b37596127cf208), fnv1a_hash(&[_]u8{ 0x40, 0x51, 0x4e, 0x54 }));
    try std.testing.expectEqual(@as(u64, 0x4b7b10fa9fe83936), fnv1a_hash(&[_]u8{ 0x54, 0x4e, 0x51, 0x40 }));
    try std.testing.expectEqual(@as(u64, 0xaabafe7104d914be), fnv1a_hash("127.0.0.1"));
    try std.testing.expectEqual(@as(u64, 0xf4d3180b3cde3eda), fnv1a_hash("127.0.0.1\x00"));
    try std.testing.expectEqual(@as(u64, 0xaabafd7104d9130b), fnv1a_hash("127.0.0.2"));
    try std.testing.expectEqual(@as(u64, 0xf4cfb20b3cdb5bb1), fnv1a_hash("127.0.0.2\x00"));
    try std.testing.expectEqual(@as(u64, 0xaabafc7104d91158), fnv1a_hash("127.0.0.3"));
    try std.testing.expectEqual(@as(u64, 0xf4cc4c0b3cd87888), fnv1a_hash("127.0.0.3\x00"));
    try std.testing.expectEqual(@as(u64, 0xe729bac5d2a8d3a7), fnv1a_hash("64.81.78.68"));
    try std.testing.expectEqual(@as(u64, 0x74bc0524f4dfa4c5), fnv1a_hash("64.81.78.68\x00"));
    try std.testing.expectEqual(@as(u64, 0xe72630c5d2a5b352), fnv1a_hash("64.81.78.74"));
    try std.testing.expectEqual(@as(u64, 0x6b983224ef8fb456), fnv1a_hash("64.81.78.74\x00"));
    try std.testing.expectEqual(@as(u64, 0xe73042c5d2ae266d), fnv1a_hash("64.81.78.84"));
    try std.testing.expectEqual(@as(u64, 0x8527e324fdeb4b37), fnv1a_hash("64.81.78.84\x00"));
    try std.testing.expectEqual(@as(u64, 0x0a83c86fee952abc), fnv1a_hash("feedface"));
    try std.testing.expectEqual(@as(u64, 0x7318523267779d74), fnv1a_hash("feedface\x00"));
    try std.testing.expectEqual(@as(u64, 0x3e66d3d56b8caca1), fnv1a_hash("feedfacedaffdeed"));
    try std.testing.expectEqual(@as(u64, 0x956694a5c0095593), fnv1a_hash("feedfacedaffdeed\x00"));
    try std.testing.expectEqual(@as(u64, 0xcac54572bb1a6fc8), fnv1a_hash("feedfacedeadbeef"));
    try std.testing.expectEqual(@as(u64, 0xa7a4c9f3edebf0d8), fnv1a_hash("feedfacedeadbeef\x00"));
    try std.testing.expectEqual(@as(u64, 0x7829851fac17b143), fnv1a_hash("line 1\nline 2\nline 3"));
    try std.testing.expectEqual(@as(u64, 0x2c8f4c9af81bcf06), fnv1a_hash("chongo <Landon Curt Noll> /\\../\\"));
    try std.testing.expectEqual(@as(u64, 0xd34e31539740c732), fnv1a_hash("chongo <Landon Curt Noll> /\\../\\\x00"));
    try std.testing.expectEqual(@as(u64, 0x3605a2ac253d2db1), fnv1a_hash("chongo (Landon Curt Noll) /\\../\\"));
    try std.testing.expectEqual(@as(u64, 0x08c11b8346f4a3c3), fnv1a_hash("chongo (Landon Curt Noll) /\\../\\\x00"));
    try std.testing.expectEqual(@as(u64, 0x6be396289ce8a6da), fnv1a_hash("http://antwrp.gsfc.nasa.gov/apod/astropix.html"));
    try std.testing.expectEqual(@as(u64, 0xd9b957fb7fe794c5), fnv1a_hash("http://en.wikipedia.org/wiki/Fowler_Noll_Vo_hash"));
    try std.testing.expectEqual(@as(u64, 0x05be33da04560a93), fnv1a_hash("http://epod.usra.edu/"));
    try std.testing.expectEqual(@as(u64, 0x0957f1577ba9747c), fnv1a_hash("http://exoplanet.eu/"));
    try std.testing.expectEqual(@as(u64, 0xda2cc3acc24fba57), fnv1a_hash("http://hvo.wr.usgs.gov/cam3/"));
    try std.testing.expectEqual(@as(u64, 0x74136f185b29e7f0), fnv1a_hash("http://hvo.wr.usgs.gov/cams/HMcam/"));
    try std.testing.expectEqual(@as(u64, 0xb2f2b4590edb93b2), fnv1a_hash("http://hvo.wr.usgs.gov/kilauea/update/deformation.html"));
    try std.testing.expectEqual(@as(u64, 0xb3608fce8b86ae04), fnv1a_hash("http://hvo.wr.usgs.gov/kilauea/update/images.html"));
    try std.testing.expectEqual(@as(u64, 0x4a3a865079359063), fnv1a_hash("http://hvo.wr.usgs.gov/kilauea/update/maps.html"));
    try std.testing.expectEqual(@as(u64, 0x5b3a7ef496880a50), fnv1a_hash("http://hvo.wr.usgs.gov/volcanowatch/current_issue.html"));
    try std.testing.expectEqual(@as(u64, 0x48fae3163854c23b), fnv1a_hash("http://neo.jpl.nasa.gov/risk/"));
    try std.testing.expectEqual(@as(u64, 0x07aaa640476e0b9a), fnv1a_hash("http://norvig.com/21-days.html"));
    try std.testing.expectEqual(@as(u64, 0x2f653656383a687d), fnv1a_hash("http://primes.utm.edu/curios/home.php"));
    try std.testing.expectEqual(@as(u64, 0xa1031f8e7599d79c), fnv1a_hash("http://slashdot.org/"));
    try std.testing.expectEqual(@as(u64, 0xa31908178ff92477), fnv1a_hash("http://tux.wr.usgs.gov/Maps/155.25-19.5.html"));
    try std.testing.expectEqual(@as(u64, 0x097edf3c14c3fb83), fnv1a_hash("http://volcano.wr.usgs.gov/kilaueastatus.php"));
    try std.testing.expectEqual(@as(u64, 0xb51ca83feaa0971b), fnv1a_hash("http://www.avo.alaska.edu/activity/Redoubt.php"));
    try std.testing.expectEqual(@as(u64, 0xdd3c0d96d784f2e9), fnv1a_hash("http://www.dilbert.com/fast/"));
    try std.testing.expectEqual(@as(u64, 0x86cd26a9ea767d78), fnv1a_hash("http://www.fourmilab.ch/gravitation/orbits/"));
    try std.testing.expectEqual(@as(u64, 0xe6b215ff54a30c18), fnv1a_hash("http://www.fpoa.net/"));
    try std.testing.expectEqual(@as(u64, 0xec5b06a1c5531093), fnv1a_hash("http://www.ioccc.org/index.html"));
    try std.testing.expectEqual(@as(u64, 0x45665a929f9ec5e5), fnv1a_hash("http://www.isthe.com/cgi-bin/number.cgi"));
    try std.testing.expectEqual(@as(u64, 0x8c7609b4a9f10907), fnv1a_hash("http://www.isthe.com/chongo/bio.html"));
    try std.testing.expectEqual(@as(u64, 0x89aac3a491f0d729), fnv1a_hash("http://www.isthe.com/chongo/index.html"));
    try std.testing.expectEqual(@as(u64, 0x32ce6b26e0f4a403), fnv1a_hash("http://www.isthe.com/chongo/src/calc/lucas-calc"));
    try std.testing.expectEqual(@as(u64, 0x614ab44e02b53e01), fnv1a_hash("http://www.isthe.com/chongo/tech/astro/venus2004.html"));
    try std.testing.expectEqual(@as(u64, 0xfa6472eb6eef3290), fnv1a_hash("http://www.isthe.com/chongo/tech/astro/vita.html"));
    try std.testing.expectEqual(@as(u64, 0x9e5d75eb1948eb6a), fnv1a_hash("http://www.isthe.com/chongo/tech/comp/c/expert.html"));
    try std.testing.expectEqual(@as(u64, 0xb6d12ad4a8671852), fnv1a_hash("http://www.isthe.com/chongo/tech/comp/calc/index.html"));
    try std.testing.expectEqual(@as(u64, 0x88826f56eba07af1), fnv1a_hash("http://www.isthe.com/chongo/tech/comp/fnv/index.html"));
    try std.testing.expectEqual(@as(u64, 0x44535bf2645bc0fd), fnv1a_hash("http://www.isthe.com/chongo/tech/math/number/howhigh.html"));
    try std.testing.expectEqual(@as(u64, 0x169388ffc21e3728), fnv1a_hash("http://www.isthe.com/chongo/tech/math/number/number.html"));
    try std.testing.expectEqual(@as(u64, 0xf68aac9e396d8224), fnv1a_hash("http://www.isthe.com/chongo/tech/math/prime/mersenne.html"));
    try std.testing.expectEqual(@as(u64, 0x8e87d7e7472b3883), fnv1a_hash("http://www.isthe.com/chongo/tech/math/prime/mersenne.html#largest"));
    try std.testing.expectEqual(@as(u64, 0x295c26caa8b423de), fnv1a_hash("http://www.lavarnd.org/cgi-bin/corpspeak.cgi"));
    try std.testing.expectEqual(@as(u64, 0x322c814292e72176), fnv1a_hash("http://www.lavarnd.org/cgi-bin/haiku.cgi"));
    try std.testing.expectEqual(@as(u64, 0x8a06550eb8af7268), fnv1a_hash("http://www.lavarnd.org/cgi-bin/rand-none.cgi"));
    try std.testing.expectEqual(@as(u64, 0xef86d60e661bcf71), fnv1a_hash("http://www.lavarnd.org/cgi-bin/randdist.cgi"));
    try std.testing.expectEqual(@as(u64, 0x9e5426c87f30ee54), fnv1a_hash("http://www.lavarnd.org/index.html"));
    try std.testing.expectEqual(@as(u64, 0xf1ea8aa826fd047e), fnv1a_hash("http://www.lavarnd.org/what/nist-test.html"));
    try std.testing.expectEqual(@as(u64, 0x0babaf9a642cb769), fnv1a_hash("http://www.macosxhints.com/"));
    try std.testing.expectEqual(@as(u64, 0x4b3341d4068d012e), fnv1a_hash("http://www.mellis.com/"));
    try std.testing.expectEqual(@as(u64, 0xd15605cbc30a335c), fnv1a_hash("http://www.nature.nps.gov/air/webcams/parks/havoso2alert/havoalert.cfm"));
    try std.testing.expectEqual(@as(u64, 0x5b21060aed8412e5), fnv1a_hash("http://www.nature.nps.gov/air/webcams/parks/havoso2alert/timelines_24.cfm"));
    try std.testing.expectEqual(@as(u64, 0x45e2cda1ce6f4227), fnv1a_hash("http://www.paulnoll.com/"));
    try std.testing.expectEqual(@as(u64, 0x50ae3745033ad7d4), fnv1a_hash("http://www.pepysdiary.com/"));
    try std.testing.expectEqual(@as(u64, 0xaa4588ced46bf414), fnv1a_hash("http://www.sciencenews.org/index/home/activity/view"));
    try std.testing.expectEqual(@as(u64, 0xc1b0056c4a95467e), fnv1a_hash("http://www.skyandtelescope.com/"));
    try std.testing.expectEqual(@as(u64, 0x56576a71de8b4089), fnv1a_hash("http://www.sput.nl/~rob/sirius.html"));
    try std.testing.expectEqual(@as(u64, 0xbf20965fa6dc927e), fnv1a_hash("http://www.systemexperts.com/"));
    try std.testing.expectEqual(@as(u64, 0x569f8383c2040882), fnv1a_hash("http://www.tq-international.com/phpBB3/index.php"));
    try std.testing.expectEqual(@as(u64, 0xe1e772fba08feca0), fnv1a_hash("http://www.travelquesttours.com/index.htm"));
    try std.testing.expectEqual(@as(u64, 0x4ced94af97138ac4), fnv1a_hash("http://www.wunderground.com/global/stations/89606.html"));
    try std.testing.expectEqual(@as(u64, 0xc4112ffb337a82fb), fnv1a_hash(&repeat10("21701")));
    try std.testing.expectEqual(@as(u64, 0xd64a4fd41de38b7d), fnv1a_hash(&repeat10("M21701")));
    try std.testing.expectEqual(@as(u64, 0x4cfc32329edebcbb), fnv1a_hash(&repeat10("2^21701-1")));
    try std.testing.expectEqual(@as(u64, 0x0803564445050395), fnv1a_hash(&repeat10(&[_]u8{ 0x54, 0xc5 })));
    try std.testing.expectEqual(@as(u64, 0xaa1574ecf4642ffd), fnv1a_hash(&repeat10(&[_]u8{ 0xc5, 0x54 })));
    try std.testing.expectEqual(@as(u64, 0x694bc4e54cc315f9), fnv1a_hash(&repeat10("23209")));
    try std.testing.expectEqual(@as(u64, 0xa3d7cb273b011721), fnv1a_hash(&repeat10("M23209")));
    try std.testing.expectEqual(@as(u64, 0x577c2f8b6115bfa5), fnv1a_hash(&repeat10("2^23209-1")));
    try std.testing.expectEqual(@as(u64, 0xb7ec8c1a769fb4c1), fnv1a_hash(&repeat10(&[_]u8{ 0x5a, 0xa9 })));
    try std.testing.expectEqual(@as(u64, 0x5d5cfce63359ab19), fnv1a_hash(&repeat10(&[_]u8{ 0xa9, 0x5a })));
    try std.testing.expectEqual(@as(u64, 0x33b96c3cd65b5f71), fnv1a_hash(&repeat10("391581216093")));
    try std.testing.expectEqual(@as(u64, 0xd845097780602bb9), fnv1a_hash(&repeat10("391581*2^216093-1")));
    try std.testing.expectEqual(@as(u64, 0x84d47645d02da3d5), fnv1a_hash(&repeat10(&[_]u8{ 0x05, 0xf9, 0x9d, 0x03, 0x4c, 0x81 })));
    try std.testing.expectEqual(@as(u64, 0x83544f33b58773a5), fnv1a_hash(&repeat10("FEDCBA9876543210")));
    try std.testing.expectEqual(@as(u64, 0x9175cbb2160836c5), fnv1a_hash(&repeat10(&[_]u8{ 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 })));
    try std.testing.expectEqual(@as(u64, 0xc71b3bc175e72bc5), fnv1a_hash(&repeat10("EFCDAB8967452301")));
    try std.testing.expectEqual(@as(u64, 0x636806ac222ec985), fnv1a_hash(&repeat10(&[_]u8{ 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01 })));
    try std.testing.expectEqual(@as(u64, 0xb6ef0e6950f52ed5), fnv1a_hash(&repeat10("0123456789ABCDEF")));
    try std.testing.expectEqual(@as(u64, 0xead3d8a0f3dfdaa5), fnv1a_hash(&repeat10(&[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef })));
    try std.testing.expectEqual(@as(u64, 0x922908fe9a861ba5), fnv1a_hash(&repeat10("1032547698BADCFE")));
    try std.testing.expectEqual(@as(u64, 0x6d4821de275fd5c5), fnv1a_hash(&repeat10(&[_]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe })));
    try std.testing.expectEqual(@as(u64, 0x1fe3fce62bd816b5), fnv1a_hash(&repeat500(&[_]u8{0x00})));
    try std.testing.expectEqual(@as(u64, 0xc23e9fccd6f70591), fnv1a_hash(&repeat500(&[_]u8{0x07})));
    try std.testing.expectEqual(@as(u64, 0xc1af12bdfe16b5b5), fnv1a_hash(&repeat500("~")));
    try std.testing.expectEqual(@as(u64, 0x39e9f18f2f85e221), fnv1a_hash(&repeat500(&[_]u8{0x7f})));
}

fn repeat10(comptime bytes: []const u8) [bytes.len * 10]u8 {
    var out: [bytes.len * 10]u8 = undefined;
    for (0..10) |i| {
        for (bytes, 0..) |b, j| {
            out[i * bytes.len + j] = b;
        }
    }
    return out;
}
fn repeat500(comptime bytes: []const u8) [bytes.len * 500]u8 {
    var out: [bytes.len * 500]u8 = undefined;
    for (0..500) |i| {
        for (bytes, 0..) |b, j| {
            out[i * bytes.len + j] = b;
        }
    }
    return out;
}

const std = @import("std");

/// XRPL Transaction Engine Result Codes
///
/// Result codes indicate the outcome of transaction processing.
/// Codes are grouped by prefix:
///   tes  — Transaction Engine Success (included in ledger, applied)
///   tec  — Transaction Engine Claimed (included, fee claimed, but tx failed)
///   tef  — Transaction Engine Failure (not included, no fee)
///   tel  — Transaction Engine Local (local error, not forwarded)
///   tem  — Transaction Engine Malformed (malformed, not forwarded)
///   ter  — Transaction Engine Retry (could succeed later)

pub const ResultCode = enum(i32) {
    // ── Success ──
    tesSUCCESS = 0,

    // ── Claimed (fee consumed, tx failed) ──
    tecCLAIM = 100,
    tecPATH_PARTIAL = 101,
    tecUNFUNDED_ADD = 102,
    tecUNFUNDED_OFFER = 103,
    tecUNFUNDED_PAYMENT = 104,
    tecFAILED_PROCESSING = 105,
    tecDIR_FULL = 121,
    tecINSUF_RESERVE_LINE = 122,
    tecINSUF_RESERVE_OFFER = 123,
    tecNO_DST = 124,
    tecNO_DST_INSUF_XRP = 125,
    tecNO_LINE_INSUF_RESERVE = 126,
    tecNO_LINE_REDUNDANT = 127,
    tecPATH_DRY = 128,
    tecUNFUNDED = 129,
    tecNO_ALTERNATIVE_KEY = 130,
    tecNO_REGULAR_KEY = 131,
    tecOWNERS = 132,
    tecNO_ISSUER = 133,
    tecNO_AUTH = 134,
    tecNO_LINE = 135,
    tecINSUFF_FEE = 136,
    tecFROZEN = 137,
    tecNO_TARGET = 138,
    tecNO_PERMISSION = 139,
    tecNO_ENTRY = 140,
    tecINSUFFICIENT_RESERVE = 141,
    tecNEED_MASTER_KEY = 142,
    tecDST_TAG_NEEDED = 143,
    tecINTERNAL = 144,
    tecOVERSIZE = 145,
    tecCRYPTOCONDITION_ERROR = 146,
    tecINVARIANT_FAILED = 147,
    tecNO_SUITABLE_NFTOKEN_PAGE = 148,
    tecNFTOKEN_BUY_SELL_MISMATCH = 149,
    tecNFTOKEN_OFFER_NOT_FOUND = 150,
    tecEXPIRED = 151,
    tecTOO_SOON = 152,
    tecKILLED = 153,
    tecHAS_OBLIGATIONS = 154,
    tecDUPLICATE = 155,

    // ── Failure (not applied, no fee) ──
    tefFAILURE = -199,
    tefALREADY = -198,
    tefBAD_ADD_AUTH = -197,
    tefBAD_AUTH = -196,
    tefBAD_LEDGER = -195,
    tefCREATED = -194,
    tefEXCEPTION = -193,
    tefINTERNAL = -192,
    tefNO_AUTH_REQUIRED = -191,
    tefPAST_SEQ = -190,
    tefWRONG_PRIOR = -189,
    tefMASTER_DISABLED = -188,
    tefMAX_LEDGER = -187,
    tefBAD_SIGNATURE = -186,
    tefBAD_QUORUM = -185,
    tefNOT_MULTI_SIGNING = -184,
    tefBAD_AUTH_MASTER = -183,
    tefINVARIANT_FAILED = -182,
    tefTOO_BIG = -181,
    tefNO_TICKET = -180,
    tefNFTOKEN_IS_NOT_TRANSFERABLE = -179,

    // ── Local error ──
    telLOCAL_ERROR = -399,
    telBAD_DOMAIN = -398,
    telBAD_PATH_COUNT = -397,
    telBAD_PUBLIC_KEY = -396,
    telFAILED_PROCESSING = -395,
    telINSUF_FEE_P = -394,
    telNO_DST_PARTIAL = -393,
    telCAN_NOT_QUEUE = -392,
    telCAN_NOT_QUEUE_BALANCE = -391,
    telCAN_NOT_QUEUE_BLOCKS = -390,
    telCAN_NOT_QUEUE_BLOCKED = -389,
    telCAN_NOT_QUEUE_FEE = -388,
    telCAN_NOT_QUEUE_FULL = -387,

    // ── Malformed ──
    temMALFORMED = -299,
    temBAD_AMOUNT = -298,
    temBAD_CURRENCY = -297,
    temBAD_EXPIRATION = -296,
    temBAD_FEE = -295,
    temBAD_ISSUER = -294,
    temBAD_LIMIT = -293,
    temBAD_OFFER = -292,
    temBAD_PATH = -291,
    temBAD_PATH_LOOP = -290,
    temBAD_QUORUM = -289,
    temBAD_REGKEY = -288,
    temBAD_SEND_XRP_LIMIT = -287,
    temBAD_SEND_XRP_MAX = -286,
    temBAD_SEND_XRP_NO_DIRECT = -285,
    temBAD_SEND_XRP_PARTIAL = -284,
    temBAD_SEND_XRP_PATHS = -283,
    temBAD_SEQUENCE = -282,
    temBAD_SIGNATURE = -281,
    temBAD_SRC_ACCOUNT = -280,
    temBAD_TRANSFER_RATE = -279,
    temDST_IS_SRC = -278,
    temDST_NEEDED = -277,
    temINVALID = -276,
    temINVALID_FLAG = -275,
    temREDUNDANT = -274,
    temRIPPLE_EMPTY = -273,
    temDISABLED = -272,
    temBAD_SIGNER = -271,
    temBAD_WEIGHT = -270,
    temBAD_TICK_SIZE = -269,
    temINVALID_ACCOUNT_ID = -268,
    temCANNOT_PREAUTH_SELF = -267,
    temUNCERTAIN = -266,
    temUNKNOWN = -265,
    temSEQ_AND_TICKET = -264,
    temBAD_NFTOKEN_TRANSFER_FEE = -263,

    // ── Retry ──
    terRETRY = -99,
    terFUNDS_SPENT = -98,
    terINSUF_FEE_B = -97,
    terNO_ACCOUNT = -96,
    terNO_AUTH = -95,
    terNO_LINE = -94,
    terOWNERS = -93,
    terPRE_SEQ = -92,
    terLAST = -91,
    terNO_RIPPLE = -90,
    terQUEUED = -89,
    terPRE_TICKET = -88,

    /// Check if this is a success code
    pub fn isSuccess(self: ResultCode) bool {
        return @intFromEnum(self) >= 0 and @intFromEnum(self) < 100;
    }

    /// Check if this is a "claimed" code (fee consumed but tx failed)
    pub fn isClaimed(self: ResultCode) bool {
        return @intFromEnum(self) >= 100 and @intFromEnum(self) < 200;
    }

    /// Check if this result means the transaction was applied to the ledger
    pub fn isApplied(self: ResultCode) bool {
        return self.isSuccess() or self.isClaimed();
    }

    /// Get the human-readable name
    pub fn name(self: ResultCode) []const u8 {
        return @tagName(self);
    }
};

// ── Tests ──

test "result code: success detection" {
    try std.testing.expect(ResultCode.tesSUCCESS.isSuccess());
    try std.testing.expect(!ResultCode.tecCLAIM.isSuccess());
    try std.testing.expect(!ResultCode.tefFAILURE.isSuccess());
}

test "result code: claimed detection" {
    try std.testing.expect(ResultCode.tecCLAIM.isClaimed());
    try std.testing.expect(ResultCode.tecNO_DST.isClaimed());
    try std.testing.expect(!ResultCode.tesSUCCESS.isClaimed());
}

test "result code: applied detection" {
    try std.testing.expect(ResultCode.tesSUCCESS.isApplied());
    try std.testing.expect(ResultCode.tecCLAIM.isApplied());
    try std.testing.expect(!ResultCode.tefFAILURE.isApplied());
    try std.testing.expect(!ResultCode.temMALFORMED.isApplied());
    try std.testing.expect(!ResultCode.terRETRY.isApplied());
}

test "result code: name" {
    try std.testing.expectEqualStrings("tesSUCCESS", ResultCode.tesSUCCESS.name());
    try std.testing.expectEqualStrings("tecNO_DST", ResultCode.tecNO_DST.name());
}

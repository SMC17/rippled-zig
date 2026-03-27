const std = @import("std");

/// XRPL Field Definition — describes a single serialized field.
///
/// Each field in the XRP Ledger binary format is identified by a
/// (type_code, field_code) pair.  `is_vl` marks variable-length encoded
/// fields (Blob, AccountID) and `is_signing` indicates whether the field
/// is included in the transaction signing hash (SigningPubKey and
/// TxnSignature are notably excluded).
pub const FieldDef = struct {
    name: []const u8,
    type_code: u8,
    field_code: u8,
    is_vl: bool, // variable-length encoded
    is_signing: bool, // included in signing hash
};

// ── XRPL Type Codes (mirror of canonical.zig TypeCode) ──
const TC_UINT16: u8 = 1;
const TC_UINT32: u8 = 2;
const TC_UINT64: u8 = 3;
const TC_HASH128: u8 = 4;
const TC_HASH256: u8 = 5;
const TC_AMOUNT: u8 = 6;
const TC_BLOB: u8 = 7;
const TC_ACCOUNTID: u8 = 8;
const TC_STOBJECT: u8 = 14;
const TC_STARRAY: u8 = 15;
const TC_UINT8: u8 = 16;
const TC_HASH160: u8 = 17;
const TC_PATHSET: u8 = 18;
const TC_VECTOR256: u8 = 19;
const TC_UINT384: u8 = 20;
const TC_UINT512: u8 = 21;
const TC_ISSUE: u8 = 24;
const TC_TRANSACTION: u8 = 10001;
const TC_LEDGERENTRY: u8 = 10002;
const TC_VALIDATION: u8 = 10003;
const TC_METADATA: u8 = 10004;

// Helper: shorthand constructors for each type family
fn f(comptime name: []const u8, comptime tc: u8, comptime fc: u8, comptime vl: bool, comptime signing: bool) FieldDef {
    return .{ .name = name, .type_code = tc, .field_code = fc, .is_vl = vl, .is_signing = signing };
}

/// Complete compile-time XRPL field definition table.
///
/// Sourced from the rippled definitions.json / SField.cpp.
/// Fields are grouped by type code for readability.
pub const fields = [_]FieldDef{
    // ── UInt16 (type 1) ──
    f("CloseResolution", TC_UINT16, 1, false, true),
    f("TransactionType", TC_UINT16, 2, false, true),
    f("SignerWeight", TC_UINT16, 3, false, true),
    f("TransferFee", TC_UINT16, 4, false, true),
    f("TradingFee", TC_UINT16, 5, false, true),
    f("DiscountedFee", TC_UINT16, 6, false, true),
    f("HookStateChangeCount", TC_UINT16, 7, false, true),
    f("HookEmitCount", TC_UINT16, 8, false, true),
    f("HookExecutionIndex", TC_UINT16, 9, false, true),
    f("HookApiVersion", TC_UINT16, 10, false, true),

    // ── UInt32 (type 2) ──
    f("Flags", TC_UINT32, 2, false, true),
    f("SourceTag", TC_UINT32, 3, false, true),
    f("Sequence", TC_UINT32, 4, false, true),
    f("DestinationTag", TC_UINT32, 14, false, true),
    f("LastLedgerSequence", TC_UINT32, 27, false, true),
    f("TransactionIndex", TC_UINT32, 1, false, true),
    f("OperationLimit", TC_UINT32, 5, false, true),
    f("QualityIn", TC_UINT32, 20, false, true),
    f("QualityOut", TC_UINT32, 21, false, true),
    f("SetFlag", TC_UINT32, 18, false, true),
    f("ClearFlag", TC_UINT32, 19, false, true),
    f("SignerQuorum", TC_UINT32, 22, false, true),
    f("CancelAfter", TC_UINT32, 24, false, true),
    f("FinishAfter", TC_UINT32, 25, false, true),
    f("OfferSequence", TC_UINT32, 25, false, true),
    f("SignerListID", TC_UINT32, 23, false, true),
    f("SettleDelay", TC_UINT32, 26, false, true),
    f("TransferRate", TC_UINT32, 11, false, true),
    f("OwnerCount", TC_UINT32, 17, false, true),
    f("Expiration", TC_UINT32, 10, false, true),
    f("LedgerSequence", TC_UINT32, 6, false, true),
    f("CloseTime", TC_UINT32, 7, false, true),
    f("ParentCloseTime", TC_UINT32, 8, false, true),
    f("SigningTime", TC_UINT32, 9, false, true),
    f("ReferenceFeeUnits", TC_UINT32, 12, false, true),
    f("ReserveBase", TC_UINT32, 13, false, true),
    f("ReserveIncrement", TC_UINT32, 15, false, true),
    f("HighQualityIn", TC_UINT32, 28, false, true),
    f("HighQualityOut", TC_UINT32, 29, false, true),
    f("LowQualityIn", TC_UINT32, 30, false, true),
    f("LowQualityOut", TC_UINT32, 31, false, true),
    f("StampEscrow", TC_UINT32, 16, false, true),
    f("BondAmount", TC_UINT32, 23, false, true),
    f("FirstLedgerSequence", TC_UINT32, 26, false, true),
    f("WalletLocator", TC_UINT32, 32, false, true),
    f("WalletSize", TC_UINT32, 33, false, true),
    f("TicketCount", TC_UINT32, 40, false, true),
    f("TicketSequence", TC_UINT32, 41, false, true),
    f("NFTokenTaxon", TC_UINT32, 42, false, true),
    f("MintedNFTokens", TC_UINT32, 43, false, true),
    f("BurnedNFTokens", TC_UINT32, 44, false, true),
    f("HookStateCount", TC_UINT32, 45, false, true),
    f("EmitGeneration", TC_UINT32, 46, false, true),
    f("VoteWeight", TC_UINT32, 48, false, true),
    f("FirstNFTokenSequence", TC_UINT32, 50, false, true),
    f("OracleDocumentID", TC_UINT32, 51, false, true),

    // ── UInt64 (type 3) ──
    f("IndexNext", TC_UINT64, 1, false, true),
    f("IndexPrevious", TC_UINT64, 2, false, true),
    f("BookNode", TC_UINT64, 3, false, true),
    f("OwnerNode", TC_UINT64, 4, false, true),
    f("BaseFee", TC_UINT64, 5, false, true),
    f("ExchangeRate", TC_UINT64, 6, false, true),
    f("LowNode", TC_UINT64, 7, false, true),
    f("HighNode", TC_UINT64, 8, false, true),
    f("ReferenceCount", TC_UINT64, 9, false, true),
    f("XChainClaimID", TC_UINT64, 10, false, true),
    f("XChainAccountCreateCount", TC_UINT64, 11, false, true),
    f("XChainAccountClaimCount", TC_UINT64, 12, false, true),
    f("HookInstructionCount", TC_UINT64, 17, false, true),
    f("HookReturnCode", TC_UINT64, 18, false, true),
    f("HookStateData", TC_UINT64, 19, false, true),

    // ── Hash128 (type 4) ──
    f("EmailHash", TC_HASH128, 1, false, true),

    // ── Hash256 (type 5) ──
    f("LedgerHash", TC_HASH256, 1, false, true),
    f("ParentHash", TC_HASH256, 2, false, true),
    f("TransactionHash", TC_HASH256, 3, false, true),
    f("AccountHash", TC_HASH256, 4, false, true),
    f("PreviousTxnID", TC_HASH256, 5, false, true),
    f("LedgerIndex", TC_HASH256, 6, false, true),
    f("WalletLocatorHash", TC_HASH256, 7, false, true),
    f("RootIndex", TC_HASH256, 8, false, true),
    f("AccountTxnID", TC_HASH256, 9, false, true),
    f("NFTokenID", TC_HASH256, 10, false, true),
    f("EmitParentTxnID", TC_HASH256, 11, false, true),
    f("EmitNonce", TC_HASH256, 12, false, true),
    f("EmitHookHash", TC_HASH256, 13, false, true),
    f("BookDirectory", TC_HASH256, 16, false, true),
    f("InvoiceID", TC_HASH256, 17, false, true),
    f("Nickname", TC_HASH256, 18, false, true),
    f("Amendment", TC_HASH256, 19, false, true),
    f("HookOn", TC_HASH256, 20, false, true),
    f("Digest", TC_HASH256, 21, false, true),
    f("NFTokenBuyOffer", TC_HASH256, 22, false, true),
    f("NFTokenSellOffer", TC_HASH256, 23, false, true),
    f("TicketID", TC_HASH256, 24, false, true),
    f("Channel", TC_HASH256, 25, false, true),
    f("CheckID", TC_HASH256, 26, false, true),
    f("ValidatedHash", TC_HASH256, 27, false, true),
    f("PreviousPageMin", TC_HASH256, 28, false, true),
    f("NextPageMin", TC_HASH256, 29, false, true),

    // ── Amount (type 6) ──
    f("Amount", TC_AMOUNT, 1, false, true),
    f("Balance", TC_AMOUNT, 2, false, true),
    f("LimitAmount", TC_AMOUNT, 3, false, true),
    f("TakerPays", TC_AMOUNT, 4, false, true),
    f("TakerGets", TC_AMOUNT, 5, false, true),
    f("LowLimit", TC_AMOUNT, 6, false, true),
    f("HighLimit", TC_AMOUNT, 7, false, true),
    f("Fee", TC_AMOUNT, 8, false, true),
    f("SendMax", TC_AMOUNT, 9, false, true),
    f("DeliverMin", TC_AMOUNT, 10, false, true),
    f("MinimumOffer", TC_AMOUNT, 16, false, true),
    f("RippleEscrow", TC_AMOUNT, 17, false, true),
    f("DeliveredAmount", TC_AMOUNT, 18, false, true),
    f("NFTokenBrokerFee", TC_AMOUNT, 19, false, true),
    f("LPTokenOut", TC_AMOUNT, 20, false, true),
    f("LPTokenIn", TC_AMOUNT, 21, false, true),
    f("EPrice", TC_AMOUNT, 22, false, true),
    f("Price", TC_AMOUNT, 23, false, true),
    f("SignatureReward", TC_AMOUNT, 24, false, true),
    f("MinAccountCreateAmount", TC_AMOUNT, 25, false, true),
    f("LPTokenBalance", TC_AMOUNT, 26, false, true),
    f("BaseFeeDrops", TC_AMOUNT, 27, false, true),
    f("ReserveBaseDrops", TC_AMOUNT, 28, false, true),
    f("ReserveIncrementDrops", TC_AMOUNT, 29, false, true),
    f("LockingChainIssue", TC_AMOUNT, 30, false, true),
    f("IssuingChainIssue", TC_AMOUNT, 31, false, true),

    // ── Blob / VL (type 7) ──
    f("PublicKey", TC_BLOB, 1, true, true),
    f("MessageKey", TC_BLOB, 2, true, true),
    f("SigningPubKey", TC_BLOB, 3, true, false), // NOT signing
    f("TxnSignature", TC_BLOB, 4, true, false), // NOT signing
    f("URI", TC_BLOB, 5, true, true),
    f("Condition", TC_BLOB, 6, true, true),
    f("Domain", TC_BLOB, 7, true, true),
    f("Fulfillment", TC_BLOB, 16, true, true),
    f("MemoType", TC_BLOB, 12, true, true),
    f("MemoData", TC_BLOB, 13, true, true),
    f("SignerEntries", TC_BLOB, 8, true, true),
    f("CreateCode", TC_BLOB, 11, true, true),
    f("Signature", TC_BLOB, 9, true, false),
    f("HookReturnString", TC_BLOB, 14, true, true),
    f("HookParameterName", TC_BLOB, 15, true, true),
    f("HookParameterValue", TC_BLOB, 16, true, true),
    f("DIDDocument", TC_BLOB, 26, true, true),
    f("Data", TC_BLOB, 27, true, true),
    f("AssetClass", TC_BLOB, 28, true, true),
    f("Provider", TC_BLOB, 29, true, true),

    // ── AccountID (type 8) ──
    f("Account", TC_ACCOUNTID, 1, true, true),
    f("Owner", TC_ACCOUNTID, 2, true, true),
    f("Destination", TC_ACCOUNTID, 3, true, true),
    f("Issuer", TC_ACCOUNTID, 4, true, true),
    f("Authorize", TC_ACCOUNTID, 5, true, true),
    f("Unauthorize", TC_ACCOUNTID, 6, true, true),
    f("RegularKey", TC_ACCOUNTID, 8, true, true),
    f("NFTokenMinter", TC_ACCOUNTID, 9, true, true),
    f("EmitCallback", TC_ACCOUNTID, 10, true, true),
    f("HookAccount", TC_ACCOUNTID, 16, true, true),
    f("OtherChainSource", TC_ACCOUNTID, 18, true, true),
    f("OtherChainDestination", TC_ACCOUNTID, 19, true, true),
    f("AttestationSignerAccount", TC_ACCOUNTID, 20, true, true),
    f("AttestationRewardAccount", TC_ACCOUNTID, 21, true, true),
    f("LockingChainIssueAccount", TC_ACCOUNTID, 22, true, true),
    f("IssuingChainIssueAccount", TC_ACCOUNTID, 23, true, true),

    // ── STObject (type 14) ──
    f("TransactionMetaData", TC_STOBJECT, 2, false, true),
    f("CreatedNode", TC_STOBJECT, 3, false, true),
    f("DeletedNode", TC_STOBJECT, 4, false, true),
    f("ModifiedNode", TC_STOBJECT, 5, false, true),
    f("PreviousFields", TC_STOBJECT, 6, false, true),
    f("FinalFields", TC_STOBJECT, 7, false, true),
    f("NewFields", TC_STOBJECT, 8, false, true),
    f("TemplateEntry", TC_STOBJECT, 9, false, true),
    f("Memo", TC_STOBJECT, 10, false, true),
    f("SignerEntry", TC_STOBJECT, 16, false, true),
    f("NFToken", TC_STOBJECT, 17, false, true),
    f("EmitDetails", TC_STOBJECT, 18, false, true),
    f("Hook", TC_STOBJECT, 19, false, true),
    f("Signer", TC_STOBJECT, 20, false, true),
    f("Majority", TC_STOBJECT, 21, false, true),
    f("DisabledValidator", TC_STOBJECT, 22, false, true),
    f("EmittedTxn", TC_STOBJECT, 23, false, true),
    f("HookExecution", TC_STOBJECT, 24, false, true),
    f("HookDefinition", TC_STOBJECT, 25, false, true),
    f("HookParameter", TC_STOBJECT, 26, false, true),
    f("HookGrant", TC_STOBJECT, 27, false, true),
    f("VoteEntry", TC_STOBJECT, 28, false, true),
    f("AuctionSlot", TC_STOBJECT, 29, false, true),
    f("AuthAccount", TC_STOBJECT, 30, false, true),
    f("PriceData", TC_STOBJECT, 31, false, true),
    f("XChainClaimProofSig", TC_STOBJECT, 32, false, true),
    f("XChainCreateAccountProofSig", TC_STOBJECT, 33, false, true),
    f("XChainClaimAttestationCollectionElement", TC_STOBJECT, 34, false, true),
    f("XChainCreateAccountAttestationCollectionElement", TC_STOBJECT, 35, false, true),

    // ── STArray (type 15) ──
    f("Signers", TC_STARRAY, 3, false, false), // NOT signing
    f("SignerEntries", TC_STARRAY, 4, false, true),
    f("Template", TC_STARRAY, 5, false, true),
    f("Necessary", TC_STARRAY, 6, false, true),
    f("Sufficient", TC_STARRAY, 7, false, true),
    f("AffectedNodes", TC_STARRAY, 8, false, true),
    f("Memos", TC_STARRAY, 9, false, true),
    f("NFTokens", TC_STARRAY, 10, false, true),
    f("Hooks", TC_STARRAY, 11, false, true),
    f("VoteSlots", TC_STARRAY, 12, false, true),
    f("Majorities", TC_STARRAY, 16, false, true),
    f("DisabledValidators", TC_STARRAY, 17, false, true),
    f("HookExecutions", TC_STARRAY, 18, false, true),
    f("HookParameters", TC_STARRAY, 19, false, true),
    f("HookGrants", TC_STARRAY, 20, false, true),
    f("AuthAccounts", TC_STARRAY, 25, false, true),
    f("PriceDataSeries", TC_STARRAY, 26, false, true),
    f("XChainClaimAttestations", TC_STARRAY, 27, false, true),
    f("XChainCreateAccountAttestations", TC_STARRAY, 28, false, true),

    // ── UInt8 (type 16) ──
    f("CloseResolutionV2", TC_UINT8, 1, false, true),
    f("Method", TC_UINT8, 2, false, true),
    f("TransactionResultCode", TC_UINT8, 3, false, true),

    // ── Hash160 (type 17) ──
    f("TakerPaysCurrency", TC_HASH160, 1, false, true),
    f("TakerPaysIssuer", TC_HASH160, 2, false, true),
    f("TakerGetsCurrency", TC_HASH160, 3, false, true),
    f("TakerGetsIssuer", TC_HASH160, 4, false, true),

    // ── PathSet (type 18) ──
    f("Paths", TC_PATHSET, 1, false, true),

    // ── Vector256 (type 19) ──
    f("Indexes", TC_VECTOR256, 1, true, true),
    f("Hashes", TC_VECTOR256, 2, true, true),
    f("Amendments", TC_VECTOR256, 3, true, true),
    f("NFTokenOffers", TC_VECTOR256, 4, true, true),
};

// ── Comptime helper functions ──

/// Look up a field definition by name.  Evaluated at comptime when
/// called with a comptime-known string, otherwise usable at runtime.
pub fn fieldByName(comptime name: []const u8) FieldDef {
    @setEvalBranchQuota(10_000);
    for (fields) |fd| {
        if (comptime std.mem.eql(u8, fd.name, name)) {
            return fd;
        }
    }
    @compileError("unknown XRPL field: " ++ name);
}

/// Look up a field definition by (type_code, field_code) pair at comptime.
pub fn fieldById(comptime tc: u8, comptime fc: u8) FieldDef {
    @setEvalBranchQuota(10_000);
    for (fields) |fd| {
        if (fd.type_code == tc and fd.field_code == fc) {
            return fd;
        }
    }
    @compileError("unknown XRPL field id");
}

/// Runtime lookup by name.  Returns null when the name is not found.
pub fn fieldByNameRuntime(name: []const u8) ?FieldDef {
    for (fields) |fd| {
        if (std.mem.eql(u8, fd.name, name)) {
            return fd;
        }
    }
    return null;
}

/// Runtime lookup by (type_code, field_code).  Returns null when not found.
pub fn fieldByIdRuntime(tc: u8, fc: u8) ?FieldDef {
    for (fields) |fd| {
        if (fd.type_code == tc and fd.field_code == fc) {
            return fd;
        }
    }
    return null;
}

/// Return a comptime slice of fields that are commonly present in a
/// given transaction type.  This is a convenience mapping, not an
/// exhaustive constraint — transactions may carry additional optional
/// fields (Memos, etc.).
pub fn fieldsForTxType(comptime tx_name: []const u8) []const FieldDef {
    if (comptime std.mem.eql(u8, tx_name, "Payment")) {
        return &payment_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "OfferCreate")) {
        return &offer_create_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "OfferCancel")) {
        return &offer_cancel_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "AccountSet")) {
        return &account_set_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "TrustSet")) {
        return &trust_set_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "EscrowCreate")) {
        return &escrow_create_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "EscrowFinish")) {
        return &escrow_finish_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "EscrowCancel")) {
        return &escrow_cancel_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "SignerListSet")) {
        return &signer_list_set_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "CheckCreate")) {
        return &check_create_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "CheckCash")) {
        return &check_cash_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "CheckCancel")) {
        return &check_cancel_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "NFTokenMint")) {
        return &nftoken_mint_fields;
    } else if (comptime std.mem.eql(u8, tx_name, "SetRegularKey")) {
        return &set_regular_key_fields;
    } else {
        @compileError("unknown transaction type: " ++ tx_name);
    }
}

// ── Common fields present in every transaction ──
const common_fields = [_]FieldDef{
    fieldByName("TransactionType"),
    fieldByName("Flags"),
    fieldByName("Sequence"),
    fieldByName("Fee"),
    fieldByName("Account"),
    fieldByName("SigningPubKey"),
    fieldByName("TxnSignature"),
};

// ── Per-transaction-type field sets (common + type-specific) ──

const payment_fields = common_fields ++ [_]FieldDef{
    fieldByName("Destination"),
    fieldByName("Amount"),
    fieldByName("SendMax"),
    fieldByName("DeliverMin"),
    fieldByName("DestinationTag"),
    fieldByName("SourceTag"),
    fieldByName("LastLedgerSequence"),
    fieldByName("InvoiceID"),
};

const offer_create_fields = common_fields ++ [_]FieldDef{
    fieldByName("TakerPays"),
    fieldByName("TakerGets"),
    fieldByName("Expiration"),
    fieldByName("OfferSequence"),
    fieldByName("LastLedgerSequence"),
};

const offer_cancel_fields = common_fields ++ [_]FieldDef{
    fieldByName("OfferSequence"),
    fieldByName("LastLedgerSequence"),
};

const account_set_fields = common_fields ++ [_]FieldDef{
    fieldByName("SetFlag"),
    fieldByName("ClearFlag"),
    fieldByName("TransferRate"),
    fieldByName("Domain"),
    fieldByName("EmailHash"),
    fieldByName("LastLedgerSequence"),
};

const trust_set_fields = common_fields ++ [_]FieldDef{
    fieldByName("LimitAmount"),
    fieldByName("QualityIn"),
    fieldByName("QualityOut"),
    fieldByName("LastLedgerSequence"),
};

const escrow_create_fields = common_fields ++ [_]FieldDef{
    fieldByName("Destination"),
    fieldByName("Amount"),
    fieldByName("CancelAfter"),
    fieldByName("FinishAfter"),
    fieldByName("Condition"),
    fieldByName("DestinationTag"),
    fieldByName("LastLedgerSequence"),
};

const escrow_finish_fields = common_fields ++ [_]FieldDef{
    fieldByName("Owner"),
    fieldByName("OfferSequence"),
    fieldByName("Condition"),
    fieldByName("Fulfillment"),
    fieldByName("LastLedgerSequence"),
};

const escrow_cancel_fields = common_fields ++ [_]FieldDef{
    fieldByName("Owner"),
    fieldByName("OfferSequence"),
    fieldByName("LastLedgerSequence"),
};

const signer_list_set_fields = common_fields ++ [_]FieldDef{
    fieldByName("SignerQuorum"),
    fieldByName("LastLedgerSequence"),
};

const check_create_fields = common_fields ++ [_]FieldDef{
    fieldByName("Destination"),
    fieldByName("SendMax"),
    fieldByName("Expiration"),
    fieldByName("DestinationTag"),
    fieldByName("InvoiceID"),
    fieldByName("LastLedgerSequence"),
};

const check_cash_fields = common_fields ++ [_]FieldDef{
    fieldByName("CheckID"),
    fieldByName("Amount"),
    fieldByName("DeliverMin"),
    fieldByName("LastLedgerSequence"),
};

const check_cancel_fields = common_fields ++ [_]FieldDef{
    fieldByName("CheckID"),
    fieldByName("LastLedgerSequence"),
};

const nftoken_mint_fields = common_fields ++ [_]FieldDef{
    fieldByName("NFTokenTaxon"),
    fieldByName("TransferFee"),
    fieldByName("Issuer"),
    fieldByName("URI"),
    fieldByName("LastLedgerSequence"),
};

const set_regular_key_fields = common_fields ++ [_]FieldDef{
    fieldByName("RegularKey"),
    fieldByName("LastLedgerSequence"),
};

// ── Tests ──

test "fieldByName returns correct field at comptime" {
    const seq = comptime fieldByName("Sequence");
    try std.testing.expectEqual(@as(u8, 2), seq.type_code);
    try std.testing.expectEqual(@as(u8, 4), seq.field_code);
    try std.testing.expect(seq.is_signing);
    try std.testing.expect(!seq.is_vl);
}

test "fieldById returns correct field at comptime" {
    const fee = comptime fieldById(6, 8);
    try std.testing.expectEqualStrings("Fee", fee.name);
    try std.testing.expect(fee.is_signing);
}

test "SigningPubKey is not a signing field" {
    const spk = comptime fieldByName("SigningPubKey");
    try std.testing.expectEqual(@as(u8, 7), spk.type_code);
    try std.testing.expectEqual(@as(u8, 3), spk.field_code);
    try std.testing.expect(!spk.is_signing);
    try std.testing.expect(spk.is_vl);
}

test "TxnSignature is not a signing field" {
    const sig = comptime fieldByName("TxnSignature");
    try std.testing.expectEqual(@as(u8, 7), sig.type_code);
    try std.testing.expectEqual(@as(u8, 4), sig.field_code);
    try std.testing.expect(!sig.is_signing);
    try std.testing.expect(sig.is_vl);
}

test "Account is VL-encoded AccountID" {
    const acct = comptime fieldByName("Account");
    try std.testing.expectEqual(@as(u8, 8), acct.type_code);
    try std.testing.expectEqual(@as(u8, 1), acct.field_code);
    try std.testing.expect(acct.is_vl);
    try std.testing.expect(acct.is_signing);
}

test "Destination and Issuer lookups" {
    const dest = comptime fieldByName("Destination");
    try std.testing.expectEqual(@as(u8, 8), dest.type_code);
    try std.testing.expectEqual(@as(u8, 3), dest.field_code);

    const issuer = comptime fieldByName("Issuer");
    try std.testing.expectEqual(@as(u8, 8), issuer.type_code);
    try std.testing.expectEqual(@as(u8, 4), issuer.field_code);
}

test "Amount fields have correct type code" {
    const amount = comptime fieldByName("Amount");
    try std.testing.expectEqual(@as(u8, 6), amount.type_code);
    try std.testing.expectEqual(@as(u8, 1), amount.field_code);

    const balance = comptime fieldByName("Balance");
    try std.testing.expectEqual(@as(u8, 6), balance.type_code);
    try std.testing.expectEqual(@as(u8, 2), balance.field_code);

    const taker_pays = comptime fieldByName("TakerPays");
    try std.testing.expectEqual(@as(u8, 6), taker_pays.type_code);
    try std.testing.expectEqual(@as(u8, 4), taker_pays.field_code);

    const taker_gets = comptime fieldByName("TakerGets");
    try std.testing.expectEqual(@as(u8, 6), taker_gets.type_code);
    try std.testing.expectEqual(@as(u8, 5), taker_gets.field_code);
}

test "fieldsForTxType returns Payment fields" {
    const pay_fields = comptime fieldsForTxType("Payment");
    try std.testing.expect(pay_fields.len > 7); // common + payment-specific

    // Verify Destination is present
    var found_dest = false;
    for (pay_fields) |fd| {
        if (std.mem.eql(u8, fd.name, "Destination")) {
            found_dest = true;
        }
    }
    try std.testing.expect(found_dest);
}

test "fieldsForTxType returns OfferCreate fields" {
    const oc_fields = comptime fieldsForTxType("OfferCreate");
    var found_taker_pays = false;
    var found_taker_gets = false;
    for (oc_fields) |fd| {
        if (std.mem.eql(u8, fd.name, "TakerPays")) found_taker_pays = true;
        if (std.mem.eql(u8, fd.name, "TakerGets")) found_taker_gets = true;
    }
    try std.testing.expect(found_taker_pays);
    try std.testing.expect(found_taker_gets);
}

test "fieldsForTxType returns AccountSet fields" {
    const as_fields = comptime fieldsForTxType("AccountSet");
    var found_set_flag = false;
    var found_clear_flag = false;
    var found_domain = false;
    for (as_fields) |fd| {
        if (std.mem.eql(u8, fd.name, "SetFlag")) found_set_flag = true;
        if (std.mem.eql(u8, fd.name, "ClearFlag")) found_clear_flag = true;
        if (std.mem.eql(u8, fd.name, "Domain")) found_domain = true;
    }
    try std.testing.expect(found_set_flag);
    try std.testing.expect(found_clear_flag);
    try std.testing.expect(found_domain);
}

test "runtime lookup by name" {
    const maybe_seq = fieldByNameRuntime("Sequence");
    try std.testing.expect(maybe_seq != null);
    try std.testing.expectEqual(@as(u8, 2), maybe_seq.?.type_code);
    try std.testing.expectEqual(@as(u8, 4), maybe_seq.?.field_code);

    const missing = fieldByNameRuntime("NonExistentField");
    try std.testing.expect(missing == null);
}

test "runtime lookup by id" {
    const maybe_fee = fieldByIdRuntime(6, 8);
    try std.testing.expect(maybe_fee != null);
    try std.testing.expectEqualStrings("Fee", maybe_fee.?.name);

    const missing = fieldByIdRuntime(99, 99);
    try std.testing.expect(missing == null);
}

test "field table has at least 200 entries" {
    try std.testing.expect(fields.len >= 200);
}

test "all common fields present in every tx type field set" {
    const tx_types = [_][]const FieldDef{
        &payment_fields,
        &offer_create_fields,
        &offer_cancel_fields,
        &account_set_fields,
        &trust_set_fields,
    };
    for (tx_types) |tx_fields| {
        var found_tx_type = false;
        var found_fee = false;
        var found_account = false;
        for (tx_fields) |fd| {
            if (std.mem.eql(u8, fd.name, "TransactionType")) found_tx_type = true;
            if (std.mem.eql(u8, fd.name, "Fee")) found_fee = true;
            if (std.mem.eql(u8, fd.name, "Account")) found_account = true;
        }
        try std.testing.expect(found_tx_type);
        try std.testing.expect(found_fee);
        try std.testing.expect(found_account);
    }
}

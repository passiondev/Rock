// This file is this fork's addition (PTP-18775) and is not in upstream Rock.
// It checks the SMS segment and cost math that smsCostEstimate.partial.obs shows.
import { getSmsSegmentInfo, getSmsSendEstimate } from "../../src/Communication/CommunicationEntryWizard/smsSegmentCalculator.partial";

/** An emoji outside the Basic Multilingual Plane, so it is a surrogate pair. */
const emoji = "\u{1F600}";

/** True when the text is one half of a surrogate pair on its own. */
function isLoneSurrogate(text: string): boolean {
    return text.length === 1 && text.charCodeAt(0) >= 0xD800 && text.charCodeAt(0) <= 0xDFFF;
}

describe("getSmsSegmentInfo", () => {
    test("160 GSM-7 characters fit in one segment and 161 need two", () => {
        expect(getSmsSegmentInfo("a".repeat(160))).toMatchObject({ encoding: "GSM-7", segmentCount: 1, remainingInSegment: 0 });
        expect(getSmsSegmentInfo("a".repeat(161))).toMatchObject({ encoding: "GSM-7", segmentCount: 2 });
    });

    test("an extension character costs two septets", () => {
        expect(getSmsSegmentInfo("€".repeat(80))).toMatchObject({ encoding: "GSM-7", segmentCount: 1, length: 160 });
        expect(getSmsSegmentInfo("€".repeat(81))).toMatchObject({ encoding: "GSM-7", segmentCount: 2, length: 162 });
    });

    test("a character outside GSM 03.38 switches to UCS-2 at 70 code units", () => {
        expect(getSmsSegmentInfo("’" + "a".repeat(69))).toMatchObject({ encoding: "UCS-2", segmentCount: 1, unicodeCharacters: ["’"] });
        expect(getSmsSegmentInfo("’" + "a".repeat(70))).toMatchObject({ encoding: "UCS-2", segmentCount: 2 });
    });

    test("a surrogate pair does not span a segment boundary", () => {
        // 66 units, then a 2 unit emoji that would straddle unit 67, then more text.
        const info = getSmsSegmentInfo("a".repeat(66) + emoji + "a".repeat(10));
        expect(info.encoding).toBe("UCS-2");
        expect(info.segmentCount).toBe(2);
        expect(info.unicodeCharacters).toEqual([emoji]);
    });

    test("an empty body has no segments", () => {
        expect(getSmsSegmentInfo("")).toMatchObject({ segmentCount: 0, length: 0 });
    });
});

describe("getSmsSendEstimate", () => {
    test("a message over 1,600 code units goes as separate texts", () => {
        const estimate = getSmsSendEstimate({ message: "a".repeat(1601), recipientCount: 1, hasAttachment: false, cautionAmount: null });
        expect(estimate.chunks.map(chunk => chunk.length)).toEqual([1600, 1]);
        expect(estimate.smsSegmentsPerRecipient).toBe(12);
    });

    test("an attachment sends the last chunk as MMS", () => {
        const estimate = getSmsSendEstimate({ message: "hello", recipientCount: 10, hasAttachment: true, cautionAmount: null });
        expect(estimate.smsSegmentsPerRecipient).toBe(0);
        expect(estimate.mmsMessagesPerRecipient).toBe(1);
        expect(estimate.encoding).toBeNull();
    });

    test("the caution shows at the caution amount and is off when the amount is null or 0", () => {
        const base = { message: "a".repeat(160), recipientCount: 2400, hasAttachment: false };
        expect(getSmsSendEstimate({ ...base, cautionAmount: 25 }).isLargeSend).toBe(true);
        expect(getSmsSendEstimate({ ...base, cautionAmount: 26 }).isLargeSend).toBe(false);
        expect(getSmsSendEstimate({ ...base, cautionAmount: null }).isLargeSend).toBe(false);
        expect(getSmsSendEstimate({ ...base, cautionAmount: 0 }).isLargeSend).toBe(false);
    });

    test("an emoji split by the 1,600 code unit chunk boundary is listed whole and its removal is counted", () => {
        // The emoji's two halves are code units 1,600 and 1,601, so Rock's chunking puts
        // one half at the end of the first text and the other at the start of the second.
        const message = "a".repeat(1599) + emoji + "b";
        const estimate = getSmsSendEstimate({ message, recipientCount: 1, hasAttachment: false, cautionAmount: null });

        expect(estimate.chunks.map(chunk => chunk.length)).toEqual([1600, 2]);
        expect(estimate.encoding).toBe("UCS-2");
        expect(estimate.unicodeCharacters).toEqual([emoji]);
        expect(estimate.unicodeCharacters.some(isLoneSurrogate)).toBe(false);

        // Without the emoji the body is 1,600 GSM-7 septets in one text: 11 segments.
        expect(estimate.smsSegmentsPerRecipientWithoutUnicode).toBe(11);
    });

    test("an emoji split between the last SMS chunk and the MMS chunk is listed whole", () => {
        const message = "a".repeat(1599) + emoji + "b";
        const estimate = getSmsSendEstimate({ message, recipientCount: 1, hasAttachment: true, cautionAmount: null });

        expect(estimate.encoding).toBe("UCS-2");
        expect(estimate.unicodeCharacters).toEqual([emoji]);
        expect(estimate.smsSegmentsPerRecipientWithoutUnicode).toBe(0);
    });
});

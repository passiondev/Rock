// <copyright>
// Copyright by the Spark Development Network
//
// Licensed under the Rock Community License (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.rockrms.com/license
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// </copyright>
//

// This file is this fork's addition (PTP-18775) and is not in upstream Rock.
// It holds the SMS segment and cost math for the estimate on the SMS Editor
// step. It has no Vue and no DOM, so the math can be checked on its own.

// #region Rates

/**
 * All-in cost in US dollars of one outbound SMS segment: Twilio's price plus the carrier
 * fee. Refresh from the usage page of the Twilio console: (outbound SMS price + SMS
 * carrier fees) divided by outbound SMS segments, for a recent month.
 */
export const smsSegmentCost = 0.0106;

/** All-in cost in US dollars of one outbound MMS message, refreshed the same way. */
export const mmsMessageCost = 0.0251;

// #endregion Rates

// #region Types

/** The two encodings that carriers use for an SMS body. */
export type SmsEncoding = "GSM-7" | "UCS-2";

/** How one Twilio message body splits into billable SMS segments. */
export type SmsSegmentInfo = {
    /** GSM-7 when every character is in the GSM 03.38 sets, otherwise UCS-2. */
    encoding: SmsEncoding;

    /** The distinct characters that force UCS-2, in order of first appearance. */
    unicodeCharacters: string[];

    /** The number of segments that Twilio bills for this body. Zero for an empty body. */
    segmentCount: number;

    /** The units left in the last segment before the body needs one more segment. */
    remainingInSegment: number;

    /** The body length in septets for GSM-7, or in UTF-16 code units for UCS-2. */
    length: number;
};

/** The inputs that change the estimate for one send. */
export type SmsSendEstimateOptions = {
    /** The message body as Twilio gets it, which is the resolved preview text. */
    message: string;

    /** The number of recipients that get the message as SMS. */
    recipientCount: number;

    /** True when the message has an attachment, which makes Twilio send it as MMS. */
    hasAttachment: boolean;

    /** The cost in US dollars that triggers a caution. Null or a nonpositive amount disables it. */
    cautionAmount: number | null;
};

/** The estimated segments, messages and cost of one send. */
export type SmsSendEstimate = {
    /** The message bodies that Twilio gets, after Rock splits a long message. */
    chunks: string[];

    /** The SMS segments that each recipient gets, over every chunk sent as SMS. */
    smsSegmentsPerRecipient: number;

    /** The MMS messages that each recipient gets: 1 with an attachment, otherwise 0. */
    mmsMessagesPerRecipient: number;

    /** UCS-2 when any chunk sent as SMS is UCS-2. Null when no chunk goes as SMS. */
    encoding: SmsEncoding | null;

    /** The distinct characters that force UCS-2 in the chunks sent as SMS. */
    unicodeCharacters: string[];

    /**
     * The SMS segments per recipient without the characters that force UCS-2.
     * Null when no character forces UCS-2.
     */
    smsSegmentsPerRecipientWithoutUnicode: number | null;

    /** The units left in the last SMS segment, or null when the last chunk goes as MMS. */
    remainingInSegment: number | null;

    /** The estimated cost in US dollars for one recipient. */
    costPerRecipient: number;

    /** The SMS segments for every recipient together. */
    totalSegments: number;

    /** The MMS messages for every recipient together. */
    totalMmsMessages: number;

    /** The estimated cost in US dollars for every recipient together. */
    totalCost: number;

    /** True when a caution amount is set and the total cost reaches it. */
    isLargeSend: boolean;
};

// #endregion Types

// #region Constants

/**
 * The GSM 03.38 basic character set. Each character costs 1 septet. The escape
 * code (0x1B) is left out because it is not a character that a person types.
 */
const gsmBasicCharacters = new Set<string>(Array.from(
    "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?"
    + "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
));

/**
 * The GSM 03.38 extension character set. Each character costs 2 septets,
 * because the carrier sends an escape code before it.
 */
const gsmExtensionCharacters = new Set<string>(Array.from("^{}\\[~]|€\f"));

/** Septets that fit in a GSM-7 message of one segment. */
const gsmSingleSegmentCapacity = 160;

/** Septets that fit in each segment of a longer GSM-7 message, after its header. */
const gsmMultipleSegmentCapacity = 153;

/** UTF-16 code units that fit in a UCS-2 message of one segment. */
const unicodeSingleSegmentCapacity = 70;

/** UTF-16 code units that fit in each segment of a longer UCS-2 message, after its header. */
const unicodeMultipleSegmentCapacity = 67;

/**
 * The longest body that Rock gives Twilio in one request. Rock splits a longer
 * message into separate texts of this many UTF-16 code units (Twilio.cs, SendToTwilioAsync).
 */
const twilioMaximumBodyLength = 1600;

// #endregion Constants

// #region Functions

/**
 * Gets the distinct characters that are in neither GSM 03.38 set. The loop uses
 * for...of so that a surrogate pair, such as an emoji, stays one character.
 *
 * @param body The message body.
 *
 * @returns The characters that force UCS-2, in order of first appearance.
 */
function getUnicodeCharacters(body: string): string[] {
    const unicodeCharacters = new Set<string>();

    for (const character of body) {
        if (!gsmBasicCharacters.has(character) && !gsmExtensionCharacters.has(character)) {
            unicodeCharacters.add(character);
        }
    }

    return Array.from(unicodeCharacters);
}

/**
 * Gets the septets that one character costs in GSM-7.
 *
 * @param character One character of a GSM-7 body.
 *
 * @returns 2 for an extension character, otherwise 1.
 */
function getGsmSeptetCount(character: string): number {
    return gsmExtensionCharacters.has(character) ? 2 : 1;
}

/**
 * Gets the UTF-16 code units that one character costs in UCS-2.
 *
 * @param character One character of a UCS-2 body.
 *
 * @returns 2 for a surrogate pair, such as an emoji, otherwise 1.
 */
function getUnicodeCodeUnitCount(character: string): number {
    return character.length;
}

/**
 * Counts the segments of a body. Characters go into segments one at a time,
 * because a character that costs 2 units (an extension character or a
 * surrogate pair) cannot span a segment boundary. Simple division would miss
 * the segment that this rule adds.
 *
 * @param body The message body.
 * @param getUnitCount Gets the units that one character costs.
 * @param singleSegmentCapacity The units that fit in a message of one segment.
 * @param multipleSegmentCapacity The units that fit in each segment of a longer message.
 *
 * @returns The segment count, the units left in the last segment, and the length in units.
 */
function countSegments(body: string, getUnitCount: (character: string) => number, singleSegmentCapacity: number, multipleSegmentCapacity: number): Omit<SmsSegmentInfo, "encoding" | "unicodeCharacters"> {
    const characters = Array.from(body);
    const length = characters.reduce((total, character) => total + getUnitCount(character), 0);

    if (length === 0) {
        return { segmentCount: 0, remainingInSegment: singleSegmentCapacity, length };
    }

    if (length <= singleSegmentCapacity) {
        return { segmentCount: 1, remainingInSegment: singleSegmentCapacity - length, length };
    }

    let segmentCount = 1;
    let unitsInSegment = 0;

    for (const character of characters) {
        const unitCount = getUnitCount(character);

        if (unitsInSegment + unitCount > multipleSegmentCapacity) {
            segmentCount++;
            unitsInSegment = 0;
        }

        unitsInSegment += unitCount;
    }

    return { segmentCount, remainingInSegment: multipleSegmentCapacity - unitsInSegment, length };
}

/**
 * Gets how one Twilio message body splits into SMS segments. Carriers send a
 * body as GSM-7 when they can, and as UCS-2 when one character is outside the
 * GSM 03.38 sets. UCS-2 fits fewer than half as many characters per segment.
 *
 * @param body One message body, as Twilio gets it.
 *
 * @returns The encoding, the characters that force UCS-2, and the segment counts.
 */
export function getSmsSegmentInfo(body: string): SmsSegmentInfo {
    const unicodeCharacters = getUnicodeCharacters(body);

    if (unicodeCharacters.length === 0) {
        return {
            encoding: "GSM-7",
            unicodeCharacters,
            ...countSegments(body, getGsmSeptetCount, gsmSingleSegmentCapacity, gsmMultipleSegmentCapacity)
        };
    }

    return {
        encoding: "UCS-2",
        unicodeCharacters,
        ...countSegments(body, getUnicodeCodeUnitCount, unicodeSingleSegmentCapacity, unicodeMultipleSegmentCapacity)
    };
}

/**
 * Splits a message the same way as Rock splits it before it calls Twilio:
 * fixed slices of UTF-16 code units (StringExtensions.SplitIntoChunks).
 *
 * @param message The message body.
 *
 * @returns The bodies that Twilio gets, one per separate text.
 */
function splitIntoTwilioChunks(message: string): string[] {
    if (message.length <= twilioMaximumBodyLength) {
        return [message];
    }

    const chunks: string[] = [];

    for (let i = 0; i < message.length; i += twilioMaximumBodyLength) {
        chunks.push(message.slice(i, i + twilioMaximumBodyLength));
    }

    return chunks;
}

/**
 * Gets the segment info of the chunks that go as SMS. With an attachment,
 * Rock sends the attachment with the last chunk only, so that chunk goes as
 * one MMS and the chunks before it still go as SMS.
 *
 * @param chunks The bodies that Twilio gets.
 * @param hasAttachment True when the message has an attachment.
 *
 * @returns The segment info of each chunk that goes as SMS.
 */
function getSmsChunkInfos(chunks: string[], hasAttachment: boolean): SmsSegmentInfo[] {
    const smsChunks = hasAttachment ? chunks.slice(0, -1) : chunks;

    return smsChunks.map(chunk => getSmsSegmentInfo(chunk));
}

/**
 * Gets the start of the message that goes as SMS, in whole characters. Rock
 * splits a long message into fixed slices of UTF-16 code units, so a slice can
 * end between the two halves of a surrogate pair, such as an emoji. The text
 * keeps both halves of that pair so that it can be listed and removed as one
 * character.
 *
 * @param message The message body.
 * @param chunks The bodies that Twilio gets.
 * @param smsChunkCount The number of chunks, from the start, that go as SMS.
 *
 * @returns The text of the chunks that go as SMS, without a split surrogate pair.
 */
function getSmsText(message: string, chunks: string[], smsChunkCount: number): string {
    let smsLength = chunks
        .slice(0, smsChunkCount)
        .reduce((total, chunk) => total + chunk.length, 0);

    const isPairSplit = smsLength > 0
        && smsLength < message.length
        && isHighSurrogate(message.charCodeAt(smsLength - 1))
        && isLowSurrogate(message.charCodeAt(smsLength));

    if (isPairSplit) {
        smsLength++;
    }

    return message.slice(0, smsLength);
}

/**
 * Checks if a UTF-16 code unit is the first half of a surrogate pair.
 *
 * @param codeUnit The UTF-16 code unit.
 *
 * @returns True when the code unit is a high surrogate.
 */
function isHighSurrogate(codeUnit: number): boolean {
    return codeUnit >= 0xD800 && codeUnit <= 0xDBFF;
}

/**
 * Checks if a UTF-16 code unit is the second half of a surrogate pair.
 *
 * @param codeUnit The UTF-16 code unit.
 *
 * @returns True when the code unit is a low surrogate.
 */
function isLowSurrogate(codeUnit: number): boolean {
    return codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}

/**
 * Adds up the SMS segments of one recipient for a message.
 *
 * @param message The message body.
 * @param hasAttachment True when the message has an attachment.
 *
 * @returns The SMS segments that one recipient gets.
 */
function getSmsSegmentsPerRecipient(message: string, hasAttachment: boolean): number {
    return getSmsChunkInfos(splitIntoTwilioChunks(message), hasAttachment)
        .reduce((total, info) => total + info.segmentCount, 0);
}

/**
 * Estimates the segments, MMS messages and cost of one send. The result is
 * advisory: it uses one preview body for every recipient, and one blended
 * rate for every carrier.
 *
 * @param options The message, the recipient count and the attachment state.
 *
 * @returns The estimate for one recipient and for the whole send.
 */
export function getSmsSendEstimate(options: SmsSendEstimateOptions): SmsSendEstimate {
    const recipientCount = Math.max(0, options.recipientCount);
    const chunks = splitIntoTwilioChunks(options.message);
    const smsChunkInfos = getSmsChunkInfos(chunks, options.hasAttachment);

    const smsSegmentsPerRecipient = smsChunkInfos.reduce((total, info) => total + info.segmentCount, 0);
    const mmsMessagesPerRecipient = options.hasAttachment ? 1 : 0;

    // Read the characters from the whole SMS text rather than from each chunk,
    // because a chunk boundary can split an emoji into two halves that are not
    // characters on their own and that the removal below would not find.
    const unicodeCharacters = getUnicodeCharacters(getSmsText(options.message, chunks, smsChunkInfos.length));

    let encoding: SmsEncoding | null = null;
    if (smsChunkInfos.length > 0) {
        encoding = unicodeCharacters.length > 0 ? "UCS-2" : "GSM-7";
    }

    // Count again without the characters that force UCS-2, so that the author
    // can see what removing them saves.
    let smsSegmentsPerRecipientWithoutUnicode: number | null = null;
    if (unicodeCharacters.length > 0) {
        const unicodeCharacterSet = new Set(unicodeCharacters);
        const messageWithoutUnicode = Array.from(options.message)
            .filter(character => !unicodeCharacterSet.has(character))
            .join("");

        smsSegmentsPerRecipientWithoutUnicode = getSmsSegmentsPerRecipient(messageWithoutUnicode, options.hasAttachment);
    }

    const remainingInSegment = options.hasAttachment || smsChunkInfos.length === 0
        ? null
        : smsChunkInfos[smsChunkInfos.length - 1].remainingInSegment;

    const costPerRecipient = smsSegmentsPerRecipient * smsSegmentCost + mmsMessagesPerRecipient * mmsMessageCost;

    // Round to cents so that floating point noise cannot move a send across
    // the caution level.
    const totalCost = Math.round(costPerRecipient * recipientCount * 100) / 100;

    const cautionAmount = options.cautionAmount ?? 0;

    return {
        chunks,
        smsSegmentsPerRecipient,
        mmsMessagesPerRecipient,
        encoding,
        unicodeCharacters,
        smsSegmentsPerRecipientWithoutUnicode,
        remainingInSegment,
        costPerRecipient,
        totalSegments: smsSegmentsPerRecipient * recipientCount,
        totalMmsMessages: mmsMessagesPerRecipient * recipientCount,
        totalCost,
        isLargeSend: cautionAmount > 0 && totalCost >= cautionAmount
    };
}

// #endregion Functions

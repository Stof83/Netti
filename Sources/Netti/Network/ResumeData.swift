//
//  ResumeData.swift
//  Netti
//

import Foundation

/// Reads which URL a download's resume data continues, so resume data is only used for the
/// request it came from (TM-39).
///
/// Resume data embeds its original request, headers included, and `URLSession` sends that request
/// instead of the one the engine was given. Resume data whose URL cannot be read, or differs from
/// the request's, is discarded and the download starts fresh.
enum ResumeData {

    // MARK: - Constants

    /// The archived `NSURLRequest` the download started with.
    private static let originalRequestKey = "NSURLSessionResumeOriginalRequest"
    /// The archived `NSURLRequest` last sent, after any redirect.
    private static let currentRequestKey = "NSURLSessionResumeCurrentRequest"
    /// The download's URL as a string, kept by every resume data format so far.
    private static let downloadURLKey = "NSURLSessionDownloadURL"

    // MARK: - Reading

    /// `resumeData` when it continues a download of `url`; `nil` otherwise, so the caller starts a
    /// fresh download of its own request.
    static func usable(_ resumeData: Data?, for url: URL?) -> Data? {
        guard let resumeData, let url, originalURL(of: resumeData)?.absoluteString == url.absoluteString else {
            return nil
        }
        return resumeData
    }

    /// The URL of the request `resumeData` was created from, or `nil` when it cannot be read.
    ///
    /// Reads the original request first, then the current request, then the download URL string.
    static func originalURL(of resumeData: Data) -> URL? {
        guard let info = dictionary(from: resumeData) else {
            return nil
        }
        for key in [originalRequestKey, currentRequestKey] {
            if let archived = info[key] as? Data,
               let request = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURLRequest.self, from: archived),
               let url = request.url {
                return url
            }
        }
        return (info[downloadURLKey] as? String).flatMap { URL(string: $0) }
    }
}

// MARK: - Private Helpers

private extension ResumeData {
    /// The resume data's dictionary: a property list, or a keyed archive of one, decoded securely.
    ///
    /// `URLSession` archives the dictionary under the literal key `"NSKeyedArchiveRootObjectKey"`,
    /// not under `NSKeyedArchiveRootObjectKey`'s value (`"root"`), so both are tried.
    static func dictionary(from resumeData: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: resumeData, format: nil) as? [String: Any] else {
            return nil
        }
        guard plist["$archiver"] != nil, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: resumeData) else {
            return plist
        }
        defer { unarchiver.finishDecoding() }
        unarchiver.requiresSecureCoding = true
        let classes = [NSDictionary.self, NSString.self, NSData.self, NSNumber.self]
        for key in ["NSKeyedArchiveRootObjectKey", NSKeyedArchiveRootObjectKey] {
            if let dictionary = unarchiver.decodeObject(of: classes, forKey: key) as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }
}

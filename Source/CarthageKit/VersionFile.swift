//
//  VersionFile.swift
//  Carthage
//
//  Created by Jason Boyle on 8/11/16.
//  Copyright © 2016 Carthage. All rights reserved.
//

import Foundation
import Argo
import Curry
import ReactiveCocoa
import ReactiveTask

private struct CachedFramework {
	let name: String
	let md5: String
	
	static let nameKey = "name"
	static let md5Key = "md5"
	
	func toJSONObject() -> AnyObject {
		return [
			CachedFramework.nameKey: name,
			CachedFramework.md5Key: md5
		]
	}
}

extension CachedFramework: Decodable {
	static func decode(j: JSON) -> Decoded<CachedFramework> {
		return curry(self.init)
			<^> j <| CachedFramework.nameKey
			<*> j <| CachedFramework.md5Key
	}
}

private struct VersionFile {
	let commitish: String
	// TODO: Xcode/Clang version
	
	let macOS: [CachedFramework]?
	let iOS: [CachedFramework]?
	let watchOS: [CachedFramework]?
	let tvOS: [CachedFramework]?
	
	static let commitishKey = "commitish"
	
	func cachesForPlatform(platform: Platform) -> [CachedFramework]? {
		switch platform {
		case .macOS:
			return macOS
		case .iOS:
			return iOS
		case .watchOS:
			return watchOS
		case .tvOS:
			return tvOS
		}
	}
	
	func cachedPlatforms() -> Set<Platform> {
		return Set(Platform.supportedPlatforms.filter { self.cachesForPlatform($0) != nil })
	}
	
	func toJSONObject() -> AnyObject {
		var dict: [String: AnyObject] = [:]
		dict[VersionFile.commitishKey] = commitish
		for platform in Platform.supportedPlatforms {
			if let caches = cachesForPlatform(platform) {
				dict[platform.rawValue] = caches.map { $0.toJSONObject() }
			}
		}
		return dict
	}
	
	init(commitish: String, macOS: [CachedFramework]?, iOS: [CachedFramework]?, watchOS: [CachedFramework]?, tvOS: [CachedFramework]?) {
		self.commitish = commitish
		
		self.macOS = macOS
		self.iOS = iOS
		self.watchOS = watchOS
		self.tvOS = tvOS
	}
	
	init?(url: URL) {
		guard NSFileManager.defaultManager().fileExistsAtPath(url.path!),
			let jsonData = NSData(contentsOfFile: url.path!),
			let json = try? NSJSONSerialization.JSONObjectWithData(jsonData, options: .AllowFragments),
			let versionFile: VersionFile = Argo.decode(json) else {
			return nil
		}
		self = versionFile
	}
	
	func check(platform: Platform, commitish: String, rootDirectoryURL: URL) -> Bool {
		guard commitish == self.commitish else {
			return false
		}
		
		let rootBinariesURL = rootDirectoryURL.appendingPathComponent(CarthageBinariesFolderPath, isDirectory: true).URLByResolvingSymlinksInPath!
		guard let cachedFrameworks = cachesForPlatform(platform) else {
			return false
		}
		
		do {
			for cachedFramework in cachedFrameworks {
				let platformURL = rootBinariesURL.appendingPathComponent(platform.rawValue, isDirectory: true).URLByResolvingSymlinksInPath!
				let frameworkURL = platformURL.appendingPathComponent("\(cachedFramework.name).framework", isDirectory: true)
				let frameworkBinaryURL = frameworkURL.appendingPathComponent("\(cachedFramework.name)", isDirectory: false)
				guard let md5 = try md5ForFileAtURL(frameworkBinaryURL) where md5 == cachedFramework.md5 else {
					return false
				}
			}
		}
		catch {
			return false
		}
		
		return true
	}
	
	func write(to url: URL) throws {
		let json = toJSONObject()
		let jsonData = try NSJSONSerialization.dataWithJSONObject(json, options: .PrettyPrinted)
		try jsonData.writeToURL(url, options: .DataWritingAtomic)
	}
}

extension VersionFile: Decodable {
	static func decode(j: JSON) -> Decoded<VersionFile> {
		return curry(self.init)
			<^> j <| VersionFile.commitishKey
			<*> j <||? Platform.macOS.rawValue
			<*> j <||? Platform.iOS.rawValue
			<*> j <||? Platform.watchOS.rawValue
			<*> j <||? Platform.tvOS.rawValue
	}
}

/// Creates a version file for the current dependency in the
/// Carthage/Build directory which associates its commitish with
/// the SHA1s of the built frameworks for each platform in order
/// to allow those frameworks to be skipped in future builds.
///
/// Returns a signal that succeeds once the file has been created.
public func createVersionFileForDependency(dependency: Dependency<PinnedVersion>, forPlatforms platforms: Set<Platform>, buildProductURLs: [URL], rootDirectoryURL: URL) -> SignalProducer<(), CarthageError> {
	return SignalProducer.attempt {
			var platformCaches: [String: [CachedFramework]] = [:]
		
			let platformsToCache = platforms.isEmpty ? Set(Platform.supportedPlatforms) : platforms
			for platform in platformsToCache {
				platformCaches[platform.rawValue] = []
			}
			
			for url in buildProductURLs {
				guard let platformName = url.URLByDeletingLastPathComponent?.lastPathComponent,
					let frameworkName = url.URLByDeletingPathExtension?.lastPathComponent else {
					return .failure(.versionFileError(description: "unable to construct version file path"))
				}
				let frameworkURL = url.appendingPathComponent(frameworkName, isDirectory: false)
				do {
					guard let md5 = try md5ForFileAtURL(frameworkURL) else {
						return .failure(.versionFileError(description: "unable to generate md5 for framework"))
					}
					let cachedFramework = CachedFramework(name: frameworkName, md5: md5)
					
					if var frameworks = platformCaches[platformName] {
						frameworks.append(cachedFramework)
						platformCaches[platformName] = frameworks
					}
					else {
						return .failure(.versionFileError(description: "unexpected platform found in path"))
					}
				}
				catch let error as NSError {
					return .failure(.readFailed(frameworkURL, error))
				}
			}
			
			let rootBinariesURL = rootDirectoryURL.appendingPathComponent(CarthageBinariesFolderPath, isDirectory: true).URLByResolvingSymlinksInPath!
			let versionFileURL = rootBinariesURL.appendingPathComponent(".\(dependency.project.name).version")
			
			let versionFile = VersionFile(
				commitish: dependency.version.commitish,
				macOS: platformCaches[Platform.macOS.rawValue],
				iOS: platformCaches[Platform.iOS.rawValue],
				watchOS: platformCaches[Platform.watchOS.rawValue],
				tvOS: platformCaches[Platform.tvOS.rawValue])
		
			do {
				try versionFile.write(to: versionFileURL)
			}
			catch let error as NSError {
				return .failure(.writeFailed(versionFileURL, error))
			}
		
			return .success(())
		}
}

/// Determines whether a dependency can be skipped because it is
/// already cached.
///
/// If a set of platforms is not provided and a version file exists,
/// the platforms in the version file are used instead.
///
/// Returns true if the the dependency can be skipped.
public func versionFileMatchesDependency(dependency: Dependency<PinnedVersion>, forPlatforms platforms: Set<Platform>, rootDirectoryURL: URL) -> Bool {
	let rootBinariesURL = rootDirectoryURL.appendingPathComponent(CarthageBinariesFolderPath, isDirectory: true).URLByResolvingSymlinksInPath!
	let versionFileURL = rootBinariesURL.appendingPathComponent(".\(dependency.project.name).version")
	guard let versionFile = VersionFile(url: versionFileURL) else {
		return false
	}
	let commitish = dependency.version.commitish
	
	let cachedPlatforms = versionFile.cachedPlatforms()
	let platformsToCheck = platforms.isEmpty ? cachedPlatforms : platforms
	for platform in platformsToCheck {
		if !versionFile.check(platform, commitish: commitish, rootDirectoryURL: rootDirectoryURL) {
			return false
		}
	}
	
	return true
}

private func md5ForFileAtURL(frameworkFileURL: URL) throws -> String? {
	guard let path = frameworkFileURL.path where NSFileManager.defaultManager().fileExistsAtPath(path) else {
		return nil
	}
	let frameworkData = try NSData(contentsOfFile: path, options: .DataReadingMappedAlways)
	return frameworkData.sha1()?.toHexString() // shasum
}

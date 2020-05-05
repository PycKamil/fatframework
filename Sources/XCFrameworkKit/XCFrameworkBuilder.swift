//
//  XCFrameworkBuilder.swift
//  XCFrameworkKit
//
//  Created by Jeff Lett on 6/8/19.
//

import Foundation
import Shell

public class XCFrameworkBuilder {
    public var name: String?
    public var project: String?
    public var outputDirectory: String?
    public var buildDirectory: String?
    public var iOSScheme: String?
    public var watchOSScheme: String?
    public var tvOSScheme: String?
    public var macOSScheme: String?
    public var xcodePath: String?
    public var verbose: Bool = false
    public var compilerArguments: [String]?
    
    public enum XCFrameworkError: Error {
        case nameNotFound
        case projectNotFound
        case noSchemesFound
        case buildDirectoryNotFound
        case outputDirectoryNotFound
        case buildError(String)
        
        public var description: String {
            switch self {
            case .nameNotFound:
                return "No name parameter found."
            case .projectNotFound:
                return "No project parameter found."
            case .noSchemesFound:
                return "No schemes found."
            case .buildDirectoryNotFound:
                return "No build directory found."
            case .outputDirectoryNotFound:
                return "No output directory found."
            case .buildError(let stderr):
                return stderr
            }
        }
    }
    
    private enum SDK: String {
        case iOS = "iphoneos"
        case watchOS = "watchos"
        case tvOS = "appletvos"
        case macOS = "macosx"
        case iOSSim = "iphonesimulator"
        case watchOSSim = "watchsimulator"
        case tvOSSim = "appletvsimulator"
    }
    
    public init(configure: (XCFrameworkBuilder) -> ()) {
        configure(self)
    }
    
    public func build() -> Result<(),XCFrameworkError> {
        
        guard let name = name else {
            return .failure(XCFrameworkError.nameNotFound)
        }
        
        guard let project = project else {
            return .failure(XCFrameworkError.projectNotFound)
        }
        
        guard watchOSScheme != nil || iOSScheme != nil || macOSScheme != nil || tvOSScheme != nil else {
            return .failure(XCFrameworkError.noSchemesFound)
        }
        
        guard let outputDirectory = outputDirectory else {
            return .failure(XCFrameworkError.outputDirectoryNotFound)
        }
        
        guard let buildDirectory = buildDirectory else {
            return .failure(XCFrameworkError.buildDirectoryNotFound)
        }

        print("Creating \(name)...")
        
        //final build location
        let finalBuildDirectory = buildDirectory.hasSuffix("/") ? buildDirectory : buildDirectory + "/"
        
        //final xcframework location
        let finalOutputDirectory = outputDirectory.hasSuffix("/") ? outputDirectory : outputDirectory + "/"
        let finalOutput = finalOutputDirectory + name + ".framework"
        
        shell.usr.rm(finalOutput)
        
        let resultCreateDir = shell.bin.mkdir.dynamicallyCall(withArguments: ["-p", finalOutput])
        if !resultCreateDir.isSuccess {
            return .failure(.buildError(resultCreateDir.stderr + "\nXCFramework Build Error From Running: 'mkdir \(["-p", finalOutput].joined(separator: " "))'"))
        }
        //array of arguments for the final xcframework construction
        var frameworksArguments: [String] = []

        //try all supported SDKs
        do {
            if let watchOSScheme = watchOSScheme {
                try frameworksArguments.append(contentsOf: buildScheme(scheme: watchOSScheme, sdk: .watchOS, project: project, name: name, buildPath: finalBuildDirectory))
                try frameworksArguments.append(contentsOf: buildScheme(scheme: watchOSScheme, sdk: .watchOSSim, project: project, name: name, buildPath: finalBuildDirectory))
            }
            
            if let iOSScheme = iOSScheme {
                try frameworksArguments.append(contentsOf: buildScheme(scheme: iOSScheme, sdk: .iOS, project: project, name: name, buildPath: finalBuildDirectory))
                try frameworksArguments.append(contentsOf: buildScheme(scheme: iOSScheme, sdk: .iOSSim, project: project, name: name, buildPath: finalBuildDirectory))
            }
            
            if let tvOSScheme = tvOSScheme {
                try frameworksArguments.append(contentsOf: buildScheme(scheme: tvOSScheme, sdk: .tvOS, project: project, name: name, buildPath: finalBuildDirectory))
                try frameworksArguments.append(contentsOf: buildScheme(scheme: tvOSScheme, sdk: .tvOSSim, project: project, name: name, buildPath: finalBuildDirectory))
            }
            
            if let macOSScheme = macOSScheme {
                try frameworksArguments.append(contentsOf: buildScheme(scheme: macOSScheme, sdk: .macOS, project: project, name: name, buildPath: finalBuildDirectory))
            }
        } catch let error as XCFrameworkError {
            return .failure(error)
        } catch {
            return .failure(.buildError(error.localizedDescription))
        }
        
        let copyArguments = ["-r", frameworksArguments[0], finalOutputDirectory]
        
        let resultCopy = shell.bin.cp.dynamicallyCall(withArguments: copyArguments)
        if !resultCopy.isSuccess {
            return .failure(.buildError(resultCopy.stderr + "\nXCFramework Build Error From Running: 'cp \(copyArguments.joined(separator: " "))'"))
        }
        
        print("Combining...")
        
        let lipoArguments = ["-create", "-output",  finalOutput + "/" + name, frameworksArguments[0] + "/" + name, frameworksArguments[1] + "/" + name]
        let resultLipo = shell.lipo.dynamicallyCall(withArguments: lipoArguments)
        
        if !resultLipo.isSuccess {
            return .failure(.buildError(resultLipo.stderr + "\nXCFramework Build Error From Running: 'lipo \(lipoArguments.joined(separator: " "))'"))
        }
        
        let copyMappingsArguments = ["-r", frameworksArguments[1] + "/Modules/", finalOutput + "/Modules/"]
        let resultCopyModules = shell.bin.cp.dynamicallyCall(withArguments: copyMappingsArguments)
        
        if !resultCopyModules.isSuccess {
            return .failure(.buildError(resultCopyModules.stderr + "\nXCFramework Build Error From Running: 'cp \(copyMappingsArguments.joined(separator: " "))'"))
        }
        
        print("Success. \(finalOutput)")
        return .success(())
    }
    
    private func buildScheme(scheme: String, sdk: SDK, project: String, name: String, buildPath: String) throws -> [String] {
        print("Building scheme \(scheme) for \(sdk.rawValue)...")
        var frameworkArguments = [String]()
        //path for each scheme's archive
        let archivePath = buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
        //array of arguments for the archive of each framework
        //weird interpolation errors are forcing me to use this "" + syntax.  not sure if this is a compiler bug or not.
        var archiveArguments = ["-project", "\"" + project + "\"", "-scheme", "\"" + scheme + "\"", "archive", "SKIP_INSTALL=NO"]
        if let compilerArguments = compilerArguments {
            archiveArguments.append(contentsOf: compilerArguments)
        }
        archiveArguments.append(contentsOf: ["-archivePath", archivePath, "-sdk", sdk.rawValue])
        if verbose {
            print("   xcodebuild \(archiveArguments.joined(separator: " "))")
        }
        
        let result: Process.FancyResult
        if let xcodePath = xcodePath,
            let developerDir = URL(string:xcodePath + "/Contents/Developer/"),
            FileManager().fileExists(atPath: developerDir.absoluteString) {
            print("Using \(xcodePath)")
            shell.usr.xcode_select.dynamicallyCall(withArguments: [xcodePath])
            result = ShellTrampoline(url: developerDir).usr.bin.xcodebuild.dynamicallyCall(withArguments: archiveArguments)
        } else {
            result = shell.usr.bin.xcodebuild.dynamicallyCall(withArguments: archiveArguments)
        }
        if !result.isSuccess {
            let errorMessage = result.stderr + "\nArchive Error From Running: 'xcodebuild \(archiveArguments.joined(separator: " "))'"
            throw XCFrameworkError.buildError(errorMessage + "\n LOG:\n" + result.stdout.suffix(100_000))
        }

        //add this framework to the list for the final output command
        frameworkArguments.append(archivePath + "/Products/Library/Frameworks/\(name).framework")
        
        print("frameworkArguments :" + (frameworkArguments.last ?? "nil"))
        return frameworkArguments
    }
    
}

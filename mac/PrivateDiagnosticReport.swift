import Foundation
import Darwin

/// Explicit local diagnostics only; never accepts an arbitrary output location.
enum PrivateDiagnosticReport {
    static func openNew(_ path:String)->FileHandle? {
        let project=URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true).resolvingSymlinksInPath()
        let local=project.appendingPathComponent(".local",isDirectory:true)
        let root=local.appendingPathComponent("generic-camera-tests",isDirectory:true)
        let requested=URL(fileURLWithPath:path).standardizedFileURL
        guard FileManager.default.fileExists(atPath:project.appendingPathComponent("mac/DetachedApplications.swift").path),
              requested.deletingLastPathComponent()==root,
              requested.lastPathComponent.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}\\.json$",options:.regularExpression) != nil else{return nil}
        let projectFD=open(project.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard projectFD>=0 else{return nil};defer{close(projectFD)}
        let localFD=openat(projectFD,".local",O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard localFD>=0 else{return nil};defer{close(localFD)}
        var localMetadata=stat()
        guard fstat(localFD,&localMetadata)==0,localMetadata.st_uid==getuid(),localMetadata.st_mode & 0o022==0 else{return nil}
        let directoryFD=openat(localFD,"generic-camera-tests",O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard directoryFD>=0 else{return nil};defer{close(directoryFD)}
        var metadata=stat()
        guard fstat(directoryFD,&metadata)==0,metadata.st_uid==getuid(),metadata.st_mode & 0o077==0 else{return nil}
        let fd=openat(directoryFD,requested.lastPathComponent,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        guard fd>=0 else{return nil}
        return FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    }
}

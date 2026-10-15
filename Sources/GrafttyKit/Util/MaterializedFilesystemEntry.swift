#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum MaterializedFilesystemEntry {
    static func isDirectory(_ st: stat) -> Bool {
        #if os(Linux)
        return (st.st_mode & S_IFMT) == S_IFDIR
        #else
        return (st.st_mode & S_IFMT) == S_IFDIR && (st.st_flags & UInt32(SF_DATALESS)) == 0
        #endif
    }

    static func isRegularFile(_ st: stat) -> Bool {
        #if os(Linux)
        return (st.st_mode & S_IFMT) == S_IFREG
        #else
        return (st.st_mode & S_IFMT) == S_IFREG && (st.st_flags & UInt32(SF_DATALESS)) == 0
        #endif
    }
}

import Darwin

enum MaterializedFilesystemEntry {
    static func isDirectory(_ st: stat) -> Bool {
        (st.st_mode & S_IFMT) == S_IFDIR
            && (st.st_flags & UInt32(SF_DATALESS)) == 0
    }

    static func isRegularFile(_ st: stat) -> Bool {
        (st.st_mode & S_IFMT) == S_IFREG
            && (st.st_flags & UInt32(SF_DATALESS)) == 0
    }
}

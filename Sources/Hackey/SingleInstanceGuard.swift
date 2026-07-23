import Foundation
import Darwin

final class SingleInstanceGuard {
    private var fd: Int32 = -1

    func acquire(lockName: String = "hackey.lock") -> Bool {
        let lockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(lockName)
        fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return false
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            fd = -1
            return false
        }

        return true
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }
}

// Test-only executable: never included in the application or release artifacts.
#ifndef SHADOW_SYNC_TESTING
#error PublisherExecutionFixture is testing-only
#endif
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool owned_namespace(const char *path) {
    const char prefix[] = "/private/tmp/shadow-sync-publisher-policy-";
    if (strncmp(path, prefix, sizeof(prefix) - 1) != 0) return false;
    const char *cursor = path + sizeof(prefix) - 1;
    for (int i = 0; i < 32; i++, cursor++) {
        if (!((*cursor >= '0' && *cursor <= '9') || (*cursor >= 'a' && *cursor <= 'f'))) return false;
    }
    if (*cursor++ != '.') return false;
    size_t count = 0;
    for (; *cursor; cursor++, count++) {
        if (count >= 64 || !((*cursor >= '0' && *cursor <= '9') ||
            (*cursor >= 'a' && *cursor <= 'z') || (*cursor >= 'A' && *cursor <= 'Z') || *cursor == '-')) return false;
    }
    return count > 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    if (strcmp(argv[1], "--canary") == 0) return 0;
    if (strcmp(argv[1], "--mark") != 0) return 64;
    char path[PATH_MAX];
    if (!getcwd(path, sizeof(path)) || !owned_namespace(path)) return 65;
    int directory = open(".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return 66;
    struct stat held, named;
    if (fstat(directory, &held) != 0 || lstat(path, &named) != 0 || !S_ISDIR(held.st_mode) ||
        !S_ISDIR(named.st_mode) || held.st_uid != geteuid() || (held.st_mode & 07777) != 0700 ||
        held.st_dev != named.st_dev || held.st_ino != named.st_ino) {
        close(directory); return 67;
    }
    int marker = openat(directory, "executed-marker", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (marker < 0) { close(directory); return 68; }
    const char contents[] = "executed";
    int result = write(marker, contents, sizeof(contents) - 1) == sizeof(contents) - 1 && fsync(marker) == 0 ? 0 : 69;
    if (close(marker) != 0) result = 70;
    if (close(directory) != 0) result = 70;
    return result;
}

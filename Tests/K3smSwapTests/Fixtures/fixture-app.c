/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

/*
 * fixture-app: the stand-in for k3sm.app's executable in the swap engine
 * tests. The tests compile it with /usr/bin/cc into a scratch directory,
 * put it in fixture bundles and sign them ad hoc. It carries a Team ID stamp
 * (FIXTURE_TEAM) the way a release build of the app does, and reads what to
 * do from its bundle's sealed Resources/behaviour:
 *
 *   handshake   with --handshake, write {"pid":<own pid>,"token":"<token>"}
 *               to $FIXTURE_PRIVATE_DIR/handshake (the token read from the
 *               request file there), then stay up
 *   exit-early  exit at once with status 3
 *   silent      stay up and never answer
 *
 * "Stay up" is at most 60 seconds; the tests terminate it sooner.
 */
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef FIXTURE_TEAM
#define FIXTURE_TEAM "ABCDE12345"
#endif

__attribute__((used)) static const char team_stamp[] = "k3sm-team-id-pin:" FIXTURE_TEAM;

static void read_behaviour(const char *argv0, char *out, size_t size) {
	char exe[PATH_MAX], path[PATH_MAX + 64];
	out[0] = '\0';
	if (realpath(argv0, exe) == NULL) return;
	char *slash = strrchr(exe, '/');
	if (slash == NULL) return;
	*slash = '\0'; /* .../Contents/MacOS */
	snprintf(path, sizeof path, "%s/../Resources/behaviour", exe);
	FILE *f = fopen(path, "r");
	if (f == NULL) return;
	if (fgets(out, (int)size, f) == NULL) out[0] = '\0';
	fclose(f);
	out[strcspn(out, "\r\n")] = '\0';
}

static int answer(void) {
	const char *dir = getenv("FIXTURE_PRIVATE_DIR");
	if (dir == NULL) return -1;
	char path[PATH_MAX], temp[PATH_MAX], body[256], json[65536];
	snprintf(path, sizeof path, "%s/request.json", dir);
	FILE *f = fopen(path, "r");
	if (f == NULL) return -1;
	size_t n = fread(json, 1, sizeof json - 1, f);
	fclose(f);
	json[n] = '\0';
	const char *key = "\"token\":\"";
	char *at = strstr(json, key);
	if (at == NULL) return -1;
	at += strlen(key);
	char *end = strchr(at, '"');
	if (end == NULL || end - at != 64) return -1;
	*end = '\0';
	int len = snprintf(body, sizeof body, "{\"pid\":%d,\"token\":\"%s\"}", (int)getpid(), at);
	snprintf(temp, sizeof temp, "%s/handshake.fixture-%d", dir, (int)getpid());
	int fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (fd < 0) return -1;
	if (write(fd, body, (size_t)len) != len) { close(fd); return -1; }
	fsync(fd);
	close(fd);
	snprintf(path, sizeof path, "%s/handshake", dir);
	return rename(temp, path);
}

int main(int argc, char **argv) {
	char behaviour[64];
	read_behaviour(argv[0], behaviour, sizeof behaviour);
	if (strcmp(behaviour, "exit-early") == 0) return 3;
	int handshake = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--handshake") == 0) handshake = 1;
	}
	if (handshake && strcmp(behaviour, "handshake") == 0) answer();
	for (int i = 0; i < 60; i++) sleep(1);
	return 0;
}

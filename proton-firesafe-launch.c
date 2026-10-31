/*
 * proton-firesafe-launch: run proton-firesafe for launchd, and wait for it.
 *
 * macOS lets a launchd job read and write external disks only if the
 * program responsible for the job has Full Disk Access. For a shell script
 * that program is the shell, so granting it would cover every shell script
 * that launchd runs. This launcher stays running while proton-firesafe
 * does, as cron does for its jobs, which makes it the responsible program:
 * Full Disk Access can then be granted to it alone.
 *
 * The script's path is compiled in, so that the launcher cannot be used to
 * run anything else with that access.
 *
 * Copyright (c) 2026 Joe Abley <jabley@strandkip.nl>
 * SPDX-License-Identifier: ISC
 */

#include <err.h>
#include <errno.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/wait.h>

#ifndef SCRIPT
#error "build with -DSCRIPT='\"/path/to/proton-firesafe\"'"
#endif

extern char **environ;

int
main(int argc, char *argv[])
{
	pid_t pid;
	int error, status;

	(void)argc;
	argv[0] = SCRIPT;
	error = posix_spawn(&pid, SCRIPT, NULL, NULL, argv, environ);
	if (error != 0) {
		errno = error;
		err(127, "%s", SCRIPT);
	}

	while (waitpid(pid, &status, 0) == -1)
		if (errno != EINTR)
			err(1, "waitpid");

	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return 1;
}

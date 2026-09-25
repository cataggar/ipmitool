/* Test-only syslog sink: record daemon messages after stderr is closed. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <syslog.h>

static FILE *output(void)
{
	const char *path = getenv("IPMITOOL_TEST_SYSLOG_PATH");
	return path ? fopen(path, "a") : stderr;
}

static void finish(FILE *stream)
{
	if (stream != stderr)
		fclose(stream);
}

void openlog(const char *ident, int option, int facility)
{
	FILE *stream = output();
	(void)option;
	if (!stream)
		return;
	fprintf(stream, "openlog:%s:%d\n", ident, facility);
	finish(stream);
}

void closelog(void)
{
	FILE *stream = output();
	if (!stream)
		return;
	fputs("closelog\n", stream);
	finish(stream);
}

void syslog(int level, const char *format, ...)
{
	va_list args;
	FILE *stream = output();
	if (!stream)
		return;
	fprintf(stream, "syslog:%d:", level);
	va_start(args, format);
	vfprintf(stream, format, args);
	va_end(args);
	fputc('\n', stream);
	finish(stream);
}

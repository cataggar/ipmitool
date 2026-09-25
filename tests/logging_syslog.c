/* Test-only syslog sink: make daemon routing and severity observable. */
#include <stdarg.h>
#include <stdio.h>
#include <syslog.h>

void openlog(const char *ident, int option, int facility)
{
	(void)option;
	(void)facility;
	fprintf(stderr, "openlog:%s\n", ident);
}

void closelog(void)
{
	fputs("closelog\n", stderr);
}

void syslog(int level, const char *format, ...)
{
	va_list args;

	fprintf(stderr, "syslog:%d:", level);
	va_start(args, format);
	vfprintf(stderr, format, args);
	va_end(args);
	fputc('\n', stderr);
}

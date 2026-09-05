#ifndef HAUNT_FFI_H
#define HAUNT_FFI_H
#include <stddef.h>
#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* POSIX terminal integration. OpenTUI owns alternate-screen/output sequences. */
int haunt_terminal_open(void);
void haunt_terminal_close(void);
void haunt_terminal_size(unsigned int *width, unsigned int *height);
int haunt_wait(int timeout_ms);
int haunt_read(unsigned char *buffer, size_t capacity);
int haunt_should_quit(void);
int haunt_was_resized(void);
double haunt_now(void);
int64_t haunt_file_stamp(const char *path);
int haunt_lua_pcall(lua_State *L, int arguments, int results);
int haunt_lua_now(lua_State *L);
#endif

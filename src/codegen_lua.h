#ifndef SPINEL_CODEGEN_LUA_H
#define SPINEL_CODEGEN_LUA_H
#include "node_table.h"
/* Prism/Spinel AST -> self-contained, portable Lua 5.1 source. NULL on refusal. */
char *codegen_lua_program(const NodeTable *nt);
#endif

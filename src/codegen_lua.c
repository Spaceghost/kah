/* Kah: a Lua backend over Spinel's Prism-derived node table.
 * Lua is dynamic, so this backend deliberately consumes the tree before the
 * native backend's type analysis and C-specific rewrites. Every expression
 * is sequenced into a temporary table, preserving Ruby evaluation order and
 * avoiding Lua 5.1's 200-local limit. Nil slots carry explicit list lengths.
 */
#include "codegen_lua.h"
#include <stdarg.h>
#include <stdint.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *p; size_t n, cap; } LuaText;
typedef struct {
  const NodeTable *nt;
  LuaText out;
  int next, indent, failed, nesting, loop, block;
} LuaGen;
static void add(LuaText *b, const char *s) {
  size_t n = strlen(s);
  if (b->n + n + 1 > b->cap) {
    b->cap = (b->n + n + 1) * 2;
    char *p = realloc(b->p, b->cap);
    if (!p) { perror("kah: out of memory"); exit(1); }
    b->p = p;
  }
  memcpy(b->p + b->n, s, n + 1); b->n += n;
}
static void fmt(LuaText *b, const char *format, va_list ap) {
  va_list cp; va_copy(cp, ap);
  int n = vsnprintf(NULL, 0, format, cp); va_end(cp);
  if (n < 0) { perror("kah: formatting output"); exit(1); }
  char *s = malloc((size_t)n + 1);
  if (!s) { perror("kah: out of memory"); exit(1); }
  vsnprintf(s, (size_t)n + 1, format, ap); add(b, s); free(s);
}
static void line(LuaGen *g, const char *format, ...) {
  for (int i = 0; i < g->indent; i++) add(&g->out, "  ");
  va_list ap; va_start(ap, format); fmt(&g->out, format, ap); va_end(ap);
  add(&g->out, "\n");
}
static char *quote(const char *s, size_t n) {
  LuaText b = {0}; add(&b, "\"");
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i]; char piece[8];
    if (c == '"' || c == '\\') { piece[0] = '\\'; piece[1] = (char)c; piece[2] = 0; }
    else if (c < 32 || c >= 127) snprintf(piece, sizeof piece, "\\%03u", c);
    else { piece[0] = (char)c; piece[1] = 0; }
    add(&b, piece);
  }
  add(&b, "\""); return b.p;
}
static char *qfield(LuaGen *g, int n, const char *key) {
  const char *s = nt_str(g->nt, n, key);
  return quote(s ? s : "", s ? nt_str_len(g->nt, n, key) : 0);
}
static void refuse(LuaGen *g, int n, const char *why) {
  int fid = (int)nt_int(g->nt, n, "node_file", 0);
  const char *file = fid >= 0 && fid < g->nt->nfiles ? g->nt->files[fid] : g->nt->source_file;
  fprintf(stderr, "kah: %s:%lld: Lua backend does not support %s (%s)\n", file ? file : "<source>",
      nt_int(g->nt, n, "node_line", 1), why, nt_type(g->nt, n) ? nt_type(g->nt, n) : "absent node");
  g->failed = 1;
}
static int expr(LuaGen *, int);
static int nil_value(LuaGen *g) { int v = ++g->next; line(g, "_v[%d] = nil", v); return v; }
static int values(LuaGen *g, int node, const char *key) {
  int n = 0; const int *nodes = nt_arr(g->nt, node, key, &n);
  int *v = malloc(sizeof(int) * (size_t)(n ? n : 1));
  if (!v) { perror("kah: out of memory"); exit(1); }
  for (int i = 0; i < n; i++) v[i] = expr(g, nodes[i]);
  int result = ++g->next;
  line(g, "_v[%d] = {n = %d}", result, n);
  for (int i = 0; i < n; i++) line(g, "_v[%d][%d] = _v[%d]", result, i + 1, v[i]);
  free(v); return result;
}
static int arguments(LuaGen *g, int node) {
  return values(g, nt_ref(g->nt, node, "arguments"), "arguments");
}
static void bind(LuaGen *g, int param, int index) {
  char *name = qfield(g, param, "name");
  line(g, "_R.local_set(_e, 0, %s, _args[%d])", name, index); free(name);
}
static void parameters(LuaGen *g, int node, int block) {
  if (nt_kind(g->nt, node) == NK_BlockParametersNode) node = nt_ref(g->nt, node, "parameters");
  if (nt_kind(g->nt, node) == NK_NumberedParametersNode) {
    int count = (int)nt_int(g->nt, node, "maximum", 0);
    line(g, "_args = _R.block_args(_args, %d)", count);
    for (int i = 1; i <= count; i++) line(g, "_R.local_set(_e, 0, \"_%d\", _args[%d])", i, i);
    return;
  }
  if (node < 0) { if (!block) line(g, "_R.arity(_args, 0, 0)"); return; }
  if (nt_kind(g->nt, node) != NK_ParametersNode) { refuse(g, node, "this parameter form"); return; }
  int nr = 0, no = 0, nk = 0, np = 0;
  const int *required = nt_arr(g->nt, node, "requireds", &nr);
  const int *optional = nt_arr(g->nt, node, "optionals", &no);
  nt_arr(g->nt, node, "keywords", &nk); nt_arr(g->nt, node, "posts", &np);
  int rest = nt_ref(g->nt, node, "rest"), bp = nt_ref(g->nt, node, "block");
  if (nk || np || nt_ref(g->nt, node, "keyword_rest") >= 0) {
    refuse(g, node, "keyword or post-rest parameters"); return;
  }
  if (block) line(g, "_args = _R.block_args(_args, %d)", nr + no);
  else line(g, "_R.arity(_args, %d, %d)", nr, rest < 0 ? nr + no : -1);
  for (int i = 0; i < nr; i++) {
    if (nt_kind(g->nt, required[i]) != NK_RequiredParameterNode) refuse(g, required[i], "destructured parameters");
    bind(g, required[i], i + 1);
  }
  for (int i = 0; i < no; i++) {
    int at = nr + i + 1;
    line(g, "if _args.n < %d then", at); g->indent++;
    int value = expr(g, nt_ref(g->nt, optional[i], "value"));
    line(g, "_args[%d] = _v[%d]", at, value); g->indent--;
    line(g, "end"); bind(g, optional[i], at);
  }
  if (rest >= 0) {
    if (nt_kind(g->nt, rest) != NK_RestParameterNode) refuse(g, rest, "argument forwarding");
    char *name = qfield(g, rest, "name");
    line(g, "_R.local_set(_e, 0, %s, _R.rest(_args, %d))", name, nr + no + 1); free(name);
  }
  if (bp >= 0) {
    char *name = qfield(g, bp, "name");
    line(g, "_R.local_set(_e, 0, %s, _block)", name); free(name);
  }
}
static int block_expr(LuaGen *g, int node) {
  if (nt_kind(g->nt, node) == NK_BlockArgumentNode) return expr(g, nt_ref(g->nt, node, "expression"));
  if (nt_kind(g->nt, node) != NK_BlockNode) { refuse(g, node, "this block form"); return nil_value(g); }
  int value = ++g->next, saved_loop = g->loop, saved_block = g->block;
  line(g, "_v[%d] = _R.block(function(_args, _brk)", value); g->indent++;
  line(g, "local _e = _R.env(_e)"); line(g, "local _v = {}");
  g->loop = 0; g->block = 1;
  parameters(g, nt_ref(g->nt, node, "parameters"), 1);
  int body = expr(g, nt_ref(g->nt, node, "body"));
  line(g, "return _v[%d]", body); g->indent--; line(g, "end)");
  g->loop = saved_loop; g->block = saved_block; return value;
}
static int constant_owner(LuaGen *g, int path) {
  int owner = ++g->next;
  int parent = nt_ref(g->nt, path, "parent");
  if (nt_kind(g->nt, path) == NK_ConstantPathNode) {
    if (parent >= 0) {
      int p = expr(g, parent); line(g, "_v[%d] = _v[%d]", owner, p);
    } else line(g, "_v[%d] = _R.Object", owner);
  } else line(g, "_v[%d] = _owner", owner);
  return owner;
}
static int assignment(LuaGen *g, int node, int value) {
  char *name = qfield(g, node, "name"); int result = ++g->next;
  NodeKind kind = nt_kind(g->nt, node);
  if (kind == NK_InstanceVariableWriteNode || kind == NK_InstanceVariableOperatorWriteNode ||
      kind == NK_InstanceVariableOrWriteNode || kind == NK_InstanceVariableAndWriteNode)
    line(g, "_v[%d] = _R.ivar_set(_self, %s, _v[%d])", result, name, value);
  else if (kind == NK_ConstantWriteNode)
    line(g, "_v[%d] = _R.constset(_owner, %s, _v[%d])", result, name, value);
  else if (kind == NK_GlobalVariableWriteNode || kind == NK_GlobalVariableOperatorWriteNode ||
           kind == NK_GlobalVariableOrWriteNode || kind == NK_GlobalVariableAndWriteNode)
    line(g, "_v[%d] = _v[%d]; _globals[%s] = _v[%d]", result, value, name, value);
  else
    line(g, "_v[%d] = _R.local_set(_e, %lld, %s, _v[%d])", result, nt_int(g->nt, node, "depth", 0), name, value);
  free(name); return result;
}
static int expr_inner(LuaGen *g, int node) {
  if (node < 0) return nil_value(g);
  const NodeTable *nt = g->nt;
  NodeKind k = nt_kind(nt, node);
  int result = ++g->next;
  switch (k) {
  case NK_ProgramNode: return expr(g, nt_ref(nt, node, "statements"));
  case NK_StatementsNode: {
    int n = 0; const int *body = nt_arr(nt, node, "body", &n);
    if (!n) return nil_value(g);
    for (int i = 0; i < n; i++) result = expr(g, body[i]);
    return result;
  }
  case NK_ParenthesesNode: return expr(g, nt_ref(nt, node, "body"));
  case NK_BeginNode:
    if (nt_ref(nt, node, "rescue_clause") >= 0 || nt_ref(nt, node, "ensure_clause") >= 0 || nt_ref(nt, node, "else_clause") >= 0) {
      refuse(g, node, "rescue/ensure"); return nil_value(g);
    }
    return expr(g, nt_ref(nt, node, "statements"));
  case NK_ElseNode: case NK_EmbeddedStatementsNode: return expr(g, nt_ref(nt, node, "statements"));
  case NK_IntegerNode: {
    long long v = nt_int(nt, node, "value", 0);
    if (nt_str(nt, node, "bigval") || v > 9007199254740991LL || v < -9007199254740991LL)
      refuse(g, node, "integer literals outside the exact portable range (+/- 9007199254740991)");
    line(g, "_v[%d] = %lld", result, v); return result;
  }
  case NK_FloatNode: {
    const char *text = nt->nodes[node].content ? nt->nodes[node].content : "0.0";
    double value = strtod(text, NULL);
    /* Lua 5.1 interns +0 and -0 as the same constant. Materialize negative
       zero at runtime so its sign cannot contaminate another zero literal. */
    if (value == 0.0 && signbit(value)) text = "(-1.0 / math.huge)";
    else if (isinf(value)) text = value < 0 ? "(-math.huge)" : "math.huge";
    line(g, "_v[%d] = _R.float(%s)", result, text); return result;
  }
  case NK_StringNode: case NK_SymbolNode: {
    char *value = qfield(g, node, k == NK_StringNode ? "content" : "value");
    line(g, k == NK_StringNode ? "_v[%d] = %s" : "_v[%d] = _R.symbol(%s)", result, value); free(value); return result;
  }
  case NK_InterpolatedStringNode: {
    int count = 0; const int *parts = nt_arr(nt, node, "parts", &count);
    line(g, "_v[%d] = \"\"", result);
    for (int i = 0; i < count; i++) {
      int value = expr(g, parts[i]); line(g, "_v[%d] = _v[%d] .. _R.to_s(_v[%d])", result, result, value);
    }
    return result;
  }
  case NK_NilNode: line(g, "_v[%d] = nil", result); return result;
  case NK_TrueNode: case NK_FalseNode:
    line(g, "_v[%d] = %s", result, k == NK_TrueNode ? "true" : "false"); return result;
  case NK_SelfNode: line(g, "_v[%d] = _self", result); return result;
  case NK_LocalVariableReadNode: {
    char *name = qfield(g, node, "name");
    line(g, "_v[%d] = _R.local_get(_e, %lld, %s)", result, nt_int(nt, node, "depth", 0), name); free(name); return result;
  }
  case NK_InstanceVariableReadNode: case NK_GlobalVariableReadNode: case NK_ConstantReadNode: {
    char *name = qfield(g, node, "name");
    const char *f = k == NK_InstanceVariableReadNode ? "_v[%d] = _R.ivar_get(_self, %s)" :
      k == NK_ConstantReadNode ? "_v[%d] = _R.constget(_owner, %s)" : "_v[%d] = _globals[%s]";
    line(g, f, result, name); free(name); return result;
  }
  case NK_ConstantPathNode: {
    int owner = constant_owner(g, node); char *name = qfield(g, node, "name");
    line(g, "_v[%d] = _R.constget(_v[%d], %s)", result, owner, name); free(name); return result;
  }
  case NK_LocalVariableWriteNode: case NK_InstanceVariableWriteNode: case NK_ConstantWriteNode: case NK_GlobalVariableWriteNode:
    return assignment(g, node, expr(g, nt_ref(nt, node, "value")));
  case NK_LocalVariableOperatorWriteNode: case NK_InstanceVariableOperatorWriteNode: case NK_GlobalVariableOperatorWriteNode: {
    char *name = qfield(g, node, "name"), *op = qfield(g, node, "binary_operator");
    int current = ++g->next;
    if (k == NK_LocalVariableOperatorWriteNode)
      line(g, "_v[%d] = _R.local_get(_e, %lld, %s)", current, nt_int(nt, node, "depth", 0), name);
    else if (k == NK_GlobalVariableOperatorWriteNode) line(g, "_v[%d] = _globals[%s]", current, name);
    else line(g, "_v[%d] = _R.ivar_get(_self, %s)", current, name);
    int right = expr(g, nt_ref(nt, node, "value"));
    line(g, "_v[%d] = _R.call(_v[%d], %s, {n = 1, [1] = _v[%d]}, nil)", result, current, op, right);
    free(name); free(op); return assignment(g, node, result);
  }
  case NK_LocalVariableOrWriteNode: case NK_LocalVariableAndWriteNode:
  case NK_InstanceVariableOrWriteNode: case NK_InstanceVariableAndWriteNode:
  case NK_GlobalVariableOrWriteNode: case NK_GlobalVariableAndWriteNode: {
    char *name = qfield(g, node, "name");
    if (k == NK_LocalVariableOrWriteNode || k == NK_LocalVariableAndWriteNode)
      line(g, "_v[%d] = _R.local_get(_e, %lld, %s)", result, nt_int(nt, node, "depth", 0), name);
    else if (k == NK_GlobalVariableOrWriteNode || k == NK_GlobalVariableAndWriteNode) line(g, "_v[%d] = _globals[%s]", result, name);
    else line(g, "_v[%d] = _R.ivar_get(_self, %s)", result, name);
    int is_or = k == NK_LocalVariableOrWriteNode || k == NK_InstanceVariableOrWriteNode || k == NK_GlobalVariableOrWriteNode;
    line(g, "if %s_R.truth(_v[%d]) then", is_or ? "not " : "", result); g->indent++;
    int value = assignment(g, node, expr(g, nt_ref(nt, node, "value")));
    line(g, "_v[%d] = _v[%d]", result, value); g->indent--; line(g, "end"); free(name); return result;
  }
  case NK_ArrayNode: {
    int elements = values(g, node, "elements"); line(g, "_v[%d] = _R.array(_v[%d])", result, elements); return result;
  }
  case NK_HashNode: case NK_KeywordHashNode: {
    int count = 0; const int *elements = nt_arr(nt, node, "elements", &count);
    int pairs = ++g->next; line(g, "_v[%d] = {n = %d}", pairs, count * 2);
    for (int i = 0; i < count; i++) {
      if (nt_kind(nt, elements[i]) != NK_AssocNode) { refuse(g, elements[i], "hash splats"); continue; }
      int key = expr(g, nt_ref(nt, elements[i], "key"));
      int value = expr(g, nt_ref(nt, elements[i], "value"));
      line(g, "_v[%d][%d] = _v[%d]; _v[%d][%d] = _v[%d]", pairs, i * 2 + 1, key, pairs, i * 2 + 2, value);
    }
    line(g, "_v[%d] = _R.hash(_v[%d])", result, pairs); return result;
  }
  case NK_RangeNode: {
    int left = expr(g, nt_ref(nt, node, "left")), right = expr(g, nt_ref(nt, node, "right"));
    line(g, "_v[%d] = _R.range(_v[%d], _v[%d], %s)", result, left, right, nt_range_excl(nt, node) ? "true" : "false"); return result;
  }
  case NK_AndNode: case NK_OrNode: {
    int left = expr(g, nt_ref(nt, node, "left")); line(g, "_v[%d] = _v[%d]", result, left);
    line(g, "if %s_R.truth(_v[%d]) then", k == NK_OrNode ? "not " : "", result); g->indent++;
    int right = expr(g, nt_ref(nt, node, "right")); line(g, "_v[%d] = _v[%d]", result, right);
    g->indent--; line(g, "end"); return result;
  }
  case NK_IfNode: case NK_UnlessNode: {
    int predicate = expr(g, nt_ref(nt, node, "predicate"));
    line(g, "if %s_R.truth(_v[%d]) then", k == NK_UnlessNode ? "not " : "", predicate); g->indent++;
    int yes = expr(g, nt_ref(nt, node, "statements")); line(g, "_v[%d] = _v[%d]", result, yes);
    g->indent--; line(g, "else"); g->indent++;
    int no = expr(g, nt_ref(nt, node, k == NK_UnlessNode ? "else_clause" : "subsequent")); line(g, "_v[%d] = _v[%d]", result, no);
    g->indent--; line(g, "end"); return result;
  }
  case NK_WhileNode: case NK_UntilNode: {
    int saved_loop = g->loop, loop = ++g->next; ++g->next; g->loop = loop;
    line(g, "_v[%d] = nil", result); line(g, "_v[%d] = false", loop);
    line(g, "while true do"); g->indent++;
    int post = nt_loop_post(nt, node);
    if (!post) {
      int condition = expr(g, nt_ref(nt, node, "predicate"));
      line(g, "if %s_R.truth(_v[%d]) then break end", k == NK_WhileNode ? "not " : "", condition);
    }
    line(g, "repeat"); g->indent++;
    expr(g, nt_ref(nt, node, "statements")); g->indent--; line(g, "until true");
    line(g, "if _v[%d] then _v[%d] = _v[%d]; break end", loop, result, loop + 1);
    if (post) {
      int condition = expr(g, nt_ref(nt, node, "predicate"));
      line(g, "if %s_R.truth(_v[%d]) then break end", k == NK_WhileNode ? "not " : "", condition);
    }
    g->indent--; line(g, "end"); g->loop = saved_loop; return result;
  }
  case NK_ReturnNode: {
    int args = arguments(g, node);
    line(g, "_R.control(_ret, _v[%d].n > 1 and _R.array(_v[%d]) or _v[%d][1])", args, args, args);
    return nil_value(g);
  }
  case NK_BreakNode: case NK_NextNode: {
    int args = arguments(g, node), value = ++g->next;
    line(g, "_v[%d] = _v[%d].n > 1 and _R.array(_v[%d]) or _v[%d][1]", value, args, args, args);
    if (g->loop) {
      if (k == NK_BreakNode) line(g, "_v[%d] = true; _v[%d] = _v[%d]", g->loop, g->loop + 1, value);
      line(g, "do break end");
    } else if (g->block) {
      if (k == NK_BreakNode) line(g, "_R.control(_brk, _v[%d])", value);
      else line(g, "do return _v[%d] end", value);
    } else refuse(g, node, "break/next outside a loop or block");
    return nil_value(g);
  }
  case NK_YieldNode: {
    int args = arguments(g, node); line(g, "_v[%d] = _R.invoke(_block, _v[%d])", result, args); return result;
  }
  case NK_CallNode: {
    int receiver_node = nt_ref(nt, node, "receiver");
    const char *name = nt_str(nt, node, "name");
    if (receiver_node < 0 && name && !strcmp(name, "block_given?")) {
      line(g, "_v[%d] = _block ~= nil", result); return result;
    }
    int receiver = receiver_node < 0 ? ++g->next : expr(g, receiver_node);
    if (receiver_node < 0) line(g, "_v[%d] = _self", receiver);
    int safe = nt_safe_nav(nt, node);
    if (safe) { line(g, "_v[%d] = nil", result); line(g, "if _v[%d] ~= nil then", receiver); g->indent++; }
    int args = arguments(g, node), block_node = nt_ref(nt, node, "block");
    int block = block_node < 0 ? nil_value(g) : block_expr(g, block_node);
    char *qname = qfield(g, node, "name");
    line(g, "_v[%d] = _R.call(_v[%d], %s, _v[%d], _v[%d])", result, receiver, qname, args, block);
    if (nt_attr_write(nt, node)) line(g, "_v[%d] = _v[%d][_v[%d].n]", result, args, args);
    if (safe) { g->indent--; line(g, "end"); }
    free(qname); return result;
  }
  case NK_DefNode: {
    int receiver_node = nt_ref(nt, node, "receiver");
    int receiver = receiver_node < 0 ? nil_value(g) : expr(g, receiver_node);
    char *name = qfield(g, node, "name");
    line(g, "_v[%d] = _R.define(_owner, _v[%d], %s, function(_self, _args, _block)", result, receiver, name); free(name);
    g->indent++; line(g, "local _e = _R.env(nil)"); line(g, "local _v = {}"); line(g, "local _ret = {}");
    line(g, "return _R.run(_ret, function()"); g->indent++;
    int saved_loop = g->loop, saved_block = g->block; g->loop = 0; g->block = 0;
    parameters(g, nt_ref(nt, node, "parameters"), 0);
    int body = expr(g, nt_ref(nt, node, "body")); line(g, "return _v[%d]", body);
    g->loop = saved_loop; g->block = saved_block;
    g->indent--; line(g, "end)"); g->indent--; line(g, "end)"); return result;
  }
  case NK_ClassNode: case NK_ModuleNode: {
    int path = nt_ref(nt, node, "constant_path"), owner = constant_owner(g, path);
    if (nt_kind(nt, path) != NK_ConstantReadNode && nt_kind(nt, path) != NK_ConstantPathNode) refuse(g, path, "dynamic class names");
    int parent = expr(g, nt_ref(nt, node, "superclass")); char *name = qfield(g, path, "name");
    line(g, "_v[%d] = (function(_owner)", result); g->indent++;
    line(g, "local _self = _owner"); line(g, "local _e = _R.env(nil)"); line(g, "local _v = {}"); line(g, "local _block = nil");
    int saved_loop = g->loop, saved_block = g->block; g->loop = 0; g->block = 0;
    int body = expr(g, nt_ref(nt, node, "body")); line(g, "return _v[%d]", body);
    g->loop = saved_loop; g->block = saved_block;
    g->indent--; line(g, "end)(_R.define_class(_v[%d], %s, _v[%d], %s))", owner, name, parent, k == NK_ModuleNode ? "true" : "false");
    free(name); return result;
  }
  case NK_BlockNode: case NK_BlockArgumentNode: return block_expr(g, node);
  case NK_SourceFileNode: {
    const char *path = nt_str(nt, node, "filepath"); if (!path) path = nt->source_file;
    char *q = quote(path ? path : "", path ? strlen(path) : 0); line(g, "_v[%d] = %s", result, q); free(q); return result;
  }
  case NK_SourceLineNode: line(g, "_v[%d] = %lld", result, nt_int(nt, node, "value", nt_int(nt, node, "node_line", 1))); return result;
  default:
    refuse(g, node, "this syntax"); line(g, "_v[%d] = nil", result); return result;
  }
}
static int expr(LuaGen *g, int node) {
  if (++g->nesting > 512) { refuse(g, node, "nesting deeper than 512 nodes"); g->nesting--; return nil_value(g); }
  int value = expr_inner(g, node); g->nesting--; return value;
}
char *codegen_lua_program(const NodeTable *nt) {
  LuaGen g = {0}; g.nt = nt;
  static const char runtime[] =
#include "kah_runtime.inc"
  ;
  add(&g.out, "-- Generated by Kah: Ruby -> Lua via Prism and Spinel.\n");
  add(&g.out, runtime);
  line(&g, "local _globals = {}");
  line(&g, "local _owner = _R.Object"); line(&g, "local _self = _R.object(_owner)");
  line(&g, "do local argv = {n = #(arg or {})}; for i = 1, argv.n do argv[i] = arg[i] end; _R.constset(_owner, \"ARGV\", _R.array(argv)) end");
  line(&g, "local _e = _R.env(nil)"); line(&g, "local _v = {}"); line(&g, "local _block = nil"); line(&g, "local _ret = {}");
  line(&g, "_R.run(_ret, function()"); g.indent++;
  expr(&g, nt->root_id); g.indent--; line(&g, "end)");
  line(&g, "return _R.exports(_self)");
  if (g.failed) { free(g.out.p); return NULL; }
  return g.out.p;
}

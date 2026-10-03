#include <tree_sitter/api.h>

// Keep TSNode aggregate calls inside C. Only pointers and scalars cross the
// Zig/C boundary, avoiding target-specific aggregate calling-convention gaps.

void r2z_ts_tree_root_node(const TSTree *self, TSNode *out) {
  *out = ts_tree_root_node(self);
}

const char *r2z_ts_node_type(const TSNode *self) {
  return ts_node_type(*self);
}

uint32_t r2z_ts_node_start_byte(const TSNode *self) {
  return ts_node_start_byte(*self);
}

uint32_t r2z_ts_node_end_byte(const TSNode *self) {
  return ts_node_end_byte(*self);
}

uint32_t r2z_ts_node_named_child_count(const TSNode *self) {
  return ts_node_named_child_count(*self);
}

bool r2z_ts_node_is_named(const TSNode *self) {
  return ts_node_is_named(*self);
}

bool r2z_ts_node_has_error(const TSNode *self) {
  return ts_node_has_error(*self);
}

bool r2z_ts_node_child(const TSNode *self, uint32_t child_index, TSNode *out) {
  *out = ts_node_child(*self, child_index);
  return !ts_node_is_null(*out);
}

bool r2z_ts_node_named_child(const TSNode *self, uint32_t child_index, TSNode *out) {
  *out = ts_node_named_child(*self, child_index);
  return !ts_node_is_null(*out);
}

const char *r2z_ts_node_field_name_for_named_child(const TSNode *self,
                                                uint32_t named_child_index) {
  return ts_node_field_name_for_named_child(*self, named_child_index);
}

bool r2z_ts_node_child_by_field_name(const TSNode *self, const char *name,
                                   uint32_t name_length, TSNode *out) {
  *out = ts_node_child_by_field_name(*self, name, name_length);
  return !ts_node_is_null(*out);
}

bool r2z_ts_node_prev_named_sibling(const TSNode *self, TSNode *out) {
  *out = ts_node_prev_named_sibling(*self);
  return !ts_node_is_null(*out);
}

bool r2z_ts_node_next_named_sibling(const TSNode *self, TSNode *out) {
  *out = ts_node_next_named_sibling(*self);
  return !ts_node_is_null(*out);
}

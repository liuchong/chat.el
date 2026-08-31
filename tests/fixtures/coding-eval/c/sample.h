#ifndef CHAT_EVAL_SAMPLE_H
#define CHAT_EVAL_SAMPLE_H

#include <stdbool.h>
#include <stddef.h>

struct user {
    int id;
    const char *name;
};

struct status {
    const char *state;
};

const struct user *find_user(const struct user *users, size_t count, int user_id);
int divide_positive(unsigned left, unsigned right, unsigned *result);
int label(const char *name, char *output, size_t output_size);
int normalize_name(const char *name, char *output, size_t output_size);
bool active(struct status status);
bool is_admin(const char *role);

#endif

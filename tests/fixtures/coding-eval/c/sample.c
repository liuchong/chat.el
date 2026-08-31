#include "sample.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

static const char *label_prefix = "item";

const struct user *find_user(const struct user *users, size_t count, int user_id) {
    for (size_t index = 0; index < count; index++) {
        if (users[index].id == user_id) {
            return &users[index];
        }
    }
    return NULL;
}

int divide_positive(unsigned left, unsigned right, unsigned *result) {
    if (right == 0 || result == NULL) {
        return -1;
    }
    *result = left / right;
    return 0;
}

int label(const char *name, char *output, size_t output_size) {
    int written = snprintf(output, output_size, "%s:%s", label_prefix, name);
    return written >= 0 && (size_t)written < output_size ? 0 : -1;
}

int normalize_name(const char *name, char *output, size_t output_size) {
    size_t length = 0;
    bool pending_space = false;
    while (isspace((unsigned char)*name)) {
        name++;
    }
    for (; *name != '\0'; name++) {
        if (isspace((unsigned char)*name)) {
            pending_space = length > 0;
        } else {
            if (pending_space) {
                if (length + 1 >= output_size) return -1;
                output[length++] = ' ';
                pending_space = false;
            }
            if (length + 1 >= output_size) return -1;
            output[length++] = (char)tolower((unsigned char)*name);
        }
    }
    if (output_size == 0) return -1;
    output[length] = '\0';
    return 0;
}

bool active(struct status status) {
    return strcmp(status.state, "enabled") == 0;
}

bool is_admin(const char *role) {
    return strncmp(role, "admin", 5) == 0;
}

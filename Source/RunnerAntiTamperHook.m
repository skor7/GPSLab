#import "RunnerAntiTamperHook.h"
#import <signal.h>
#import <mach-o/dyld.h>
#import <os/log.h>

// Runner brk #1 location
static const uintptr_t kRunnerBrkOffset = 0x11DA9C;

static uintptr_t g_brk_target = 0;
static struct sigaction g_prev_action;
static os_log_t g_log;

static void runner_sigtrap_handler(int sig, siginfo_t *info, void *ucontext)
{
    ucontext_t *uc = (ucontext_t *)ucontext;
    if (uc == NULL) {
        sigaction(SIGTRAP, &g_prev_action, NULL);
        raise(SIGTRAP);
        return;
    }

#if defined(__arm64__)
    uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
#elif defined(__x86_64__)
    uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
#else
    uintptr_t pc = 0;
#endif

    if (g_brk_target != 0 && pc == g_brk_target) {
#if defined(__arm64__)
        uc->uc_mcontext->__ss.__pc = pc + 4;
#elif defined(__x86_64__)
        uc->uc_mcontext->__ss.__rip = pc + 4;
#endif
        if (g_log) {
            os_log_info(g_log, "[GPSLab] Skipped anti-tamper brk at 0x%lx", (unsigned long)pc);
        }
        return;
    }

    sigaction(SIGTRAP, &g_prev_action, NULL);
    raise(SIGTRAP);
}

@implementation RunnerAntiTamperHook

+ (void)install
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_log = os_log_create("com.gpslab.antitamper", "runner");

        const struct mach_header_64 *runner_header = NULL;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const struct mach_header *hdr = _dyld_get_image_header(i);
            const char *name = _dyld_get_image_name(i);
            if (name == NULL || hdr == NULL) continue;
            if (strstr(name, "/Runner.app/Runner") != NULL) {
                runner_header = (const struct mach_header_64 *)hdr;
                break;
            }
        }

        if (runner_header == NULL) {
            if (g_log) {
                os_log_error(g_log, "[GPSLab] Runner not found. SIGTRAP hook skipped.");
            }
            return;
        }

        g_brk_target = (uintptr_t)runner_header + kRunnerBrkOffset;
        if (g_log) {
            os_log_info(g_log, "[GPSLab] Runner base=0x%lx target=0x%lx",
                        (unsigned long)runner_header,
                        (unsigned long)g_brk_target);
        }

        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = runner_sigtrap_handler;
        sa.sa_flags = SA_SIGINFO | SA_NODEFER;
        sigemptyset(&sa.sa_mask);

        if (sigaction(SIGTRAP, &sa, &g_prev_action) != 0) {
            if (g_log) os_log_error(g_log, "[GPSLab] sigaction failed errno=%d", errno);
        } else {
            if (g_log) os_log_info(g_log, "[GPSLab] SIGTRAP handler installed.");
        }
    });
}

@end

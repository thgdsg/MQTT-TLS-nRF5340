#ifndef APP_BENCH_FEATURES_SHIM_H
#define APP_BENCH_FEATURES_SHIM_H

#ifndef __GNUC_PREREQ
#define __GNUC_PREREQ(maj, min) \
	((__GNUC__ > (maj)) || (__GNUC__ == (maj) && __GNUC_MINOR__ >= (min)))
#endif

#endif

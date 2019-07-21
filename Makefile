IGNORE_DEPS += edown eper eunit_formatters meck node_package rebar_lock_deps_plugin rebar_vsn_plugin reltool_util
C_SRC_DIR = /path/do/not/exist
C_SRC_TYPE = rebar
DRV_CFLAGS = -fPIC
export DRV_CFLAGS
ERLANG_ARCH = 64
export ERLANG_ARCH
ERLC_OPTS = +debug_info
export ERLC_OPTS
ERLC_OPTS += -I include
ERLC_OPTS += -I ../fast_xml/include
ERLC_OPTS += -I deps/fast_xml/include

DEPS += p1_utils
dep_p1_utils = git https://github.com/processone/p1_utils 1.0.15
DEPS += fast_xml
dep_fast_xml = git https://github.com/processone/fast_xml cfe69e3
DEPS += fast_tls
dep_fast_tls = git https://github.com/processone/fast_tls 1.1.1
DEPS += ezlib
dep_ezlib = git https://github.com/processone/ezlib 1.0.6
DEPS += stringprep
dep_stringprep = git https://github.com/processone/stringprep 1.0.16


rebar_dep: preprocess pre-deps deps pre-app app

preprocess::

pre-deps::

pre-app::

pre-app::
	@$(MAKE) --no-print-directory -f c_src/Makefile.erlang.mk

include $(if $(ERLANG_MK_FILENAME),$(ERLANG_MK_FILENAME),erlang.mk)
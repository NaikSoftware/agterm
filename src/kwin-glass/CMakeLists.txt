# agterm's KWin effect: GPL-2.0-or-later, a fork of KWin's blur. Built for the exact KWin found here,
# which is the only version that will load it.
add_library(agtermglass MODULE glass.cpp main.cpp glass.qrc)
set_target_properties(agtermglass PROPERTIES CXX_STANDARD 23 AUTORCC ON PREFIX "" AUTOMOC_MACRO_NAMES "Q_OBJECT;KWIN_EFFECT_FACTORY_SUPPORTED")
target_link_libraries(agtermglass PRIVATE KWin::kwin KDecoration3::KDecoration Qt6::DBus)
install(TARGETS agtermglass DESTINATION ${CMAKE_INSTALL_LIBDIR}/qt6/plugins/kwin/effects/plugins)

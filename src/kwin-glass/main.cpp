/*
    SPDX-FileCopyrightText: 2021 Vlad Zahorodnii <vlad.zahorodnii@kde.org>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "glass.h"

namespace KWin
{

KWIN_EFFECT_FACTORY_SUPPORTED(GlassEffect, "metadata.json", return GlassEffect::supported();)

} // namespace KWin

#include "main.moc"

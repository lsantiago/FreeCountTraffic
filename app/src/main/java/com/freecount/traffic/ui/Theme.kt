package com.freecount.traffic.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.freecount.traffic.core.VehicleClass

/** Clean white UI with an orange accent; pastel zone colors and per-class colors shared by every screen. */
object Palette {
    val Orange = Color(0xFFF28A0F)
    val Peach = Color(0xFFFFF1E2)
    val InkOnPeach = Color(0xFF3B2300)

    private val zones = listOf(
        Color(0xFFFFD54F), Color(0xFF64B5F6), Color(0xFFEF9A9A), Color(0xFF81C784), Color(0xFFBA68C8),
    )

    fun zone(index: Int): Color = zones[index.mod(zones.size)]

    fun cls(c: VehicleClass): Color = when (c) {
        VehicleClass.CAR -> Color(0xFFE57373)
        VehicleClass.TRUCK -> Color(0xFF42A5F5)
        VehicleClass.BUS -> Color(0xFFFFCA28)
        VehicleClass.MOTORCYCLE -> Color(0xFFAB47BC)
        VehicleClass.BICYCLE -> Color(0xFF26A69A)
        VehicleClass.PERSON -> Color(0xFF8D6E63)
    }
}

private val LightColors = lightColorScheme(
    primary = Palette.Orange,
    onPrimary = Color.White,
    primaryContainer = Palette.Peach,
    onPrimaryContainer = Palette.InkOnPeach,
    secondaryContainer = Palette.Peach,
    onSecondaryContainer = Palette.InkOnPeach,
    background = Color.White,
    surface = Color.White,
    surfaceVariant = Color(0xFFF4F4F4),
)

private val DarkColors = darkColorScheme(
    primary = Palette.Orange,
    onPrimary = Color.Black,
    primaryContainer = Color(0xFF4A3014),
    onPrimaryContainer = Color(0xFFFFE2C2),
    secondaryContainer = Color(0xFF4A3014),
    onSecondaryContainer = Color(0xFFFFE2C2),
)

private val AppTypography = Typography(
    headlineMedium = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold),
    titleLarge = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold),
    titleMedium = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
    titleSmall = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
)

@Composable
fun TrafficTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        typography = AppTypography,
        shapes = Shapes(
            small = RoundedCornerShape(10.dp),
            medium = RoundedCornerShape(14.dp),
            large = RoundedCornerShape(20.dp),
        ),
        content = content,
    )
}


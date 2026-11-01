package app.bilight.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

@Composable internal fun ActionBarLayout(
    modifier: Modifier = Modifier,
    like: @Composable (Modifier) -> Unit,
    coin: @Composable (Modifier) -> Unit,
    favorite: @Composable (Modifier) -> Unit,
    share: @Composable (Modifier) -> Unit,
    download: @Composable (Modifier) -> Unit
) {
    val fontScale = LocalDensity.current.fontScale
    BoxWithConstraints(modifier.fillMaxWidth()) {
        if (maxWidth < 280.dp || fontScale > 1.4f) {
            Column {
                Row { Box(Modifier.weight(1f)) { like(Modifier.fillMaxWidth()) }; Box(Modifier.weight(1f)) { coin(Modifier.fillMaxWidth()) } }
                Row { Box(Modifier.weight(1f)) { favorite(Modifier.fillMaxWidth()) }; Box(Modifier.weight(1f)) { share(Modifier.fillMaxWidth()) } }
                Row { Spacer(Modifier.weight(1f)); Box(Modifier.weight(1f)) { download(Modifier.fillMaxWidth()) } }
            }
        } else {
            val gap = ((maxWidth - 268.dp) / 3).coerceIn(4.dp, 24.dp)
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                like(Modifier.width(52.dp)); Spacer(Modifier.width(gap))
                coin(Modifier.width(52.dp)); Spacer(Modifier.width(gap))
                favorite(Modifier.width(52.dp)); Spacer(Modifier.width(gap))
                share(Modifier.width(52.dp)); Spacer(Modifier.weight(1f)); download(Modifier.width(52.dp))
            }
        }
    }
}

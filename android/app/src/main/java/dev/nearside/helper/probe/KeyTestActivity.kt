// Throwaway: a text field that logs every key it gets (device, key code, character).
package dev.nearside.helper.probe

import android.app.Activity
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.KeyEvent
import android.widget.EditText

class KeyTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val field = object : EditText(this) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                android.util.Log.i("KeyTest", "key action=${event.action} code=${event.keyCode} meta=${Integer.toHexString(event.metaState)} " +
                    "device=${event.deviceId} char=${event.unicodeChar.toChar()} flags=${Integer.toHexString(event.flags)}")
                return super.dispatchKeyEvent(event)
            }
        }
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) { android.util.Log.i("KeyTest", "text=\"$s\"") }
        })
        setContentView(field)
        field.requestFocus()
    }
}

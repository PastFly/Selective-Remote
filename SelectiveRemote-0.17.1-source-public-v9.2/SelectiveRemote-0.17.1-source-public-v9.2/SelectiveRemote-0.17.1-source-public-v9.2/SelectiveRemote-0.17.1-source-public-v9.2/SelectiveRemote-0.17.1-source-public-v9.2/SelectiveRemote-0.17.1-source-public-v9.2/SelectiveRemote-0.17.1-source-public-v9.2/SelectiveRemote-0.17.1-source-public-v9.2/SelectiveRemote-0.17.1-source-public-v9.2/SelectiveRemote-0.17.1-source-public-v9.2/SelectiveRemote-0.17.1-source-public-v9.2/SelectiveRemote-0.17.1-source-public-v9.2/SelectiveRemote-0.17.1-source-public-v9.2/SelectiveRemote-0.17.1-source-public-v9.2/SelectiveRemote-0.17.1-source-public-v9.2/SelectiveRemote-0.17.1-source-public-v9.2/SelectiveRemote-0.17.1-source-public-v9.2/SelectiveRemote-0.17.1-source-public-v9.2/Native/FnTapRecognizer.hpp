#pragma once

class FnTapRecognizer
{
public:
    void fnChanged(bool pressed, bool anotherModifierHeld = false)
    {
        if (pressed)
        {
            if (!_fnDown)
            {
                _fnDown = true;
                _usedWithAnotherKey = anotherModifierHeld;
                _tapReady = false;
            }
            return;
        }

        if (_fnDown)
            _tapReady = !_usedWithAnotherKey;
        _fnDown = false;
        _usedWithAnotherKey = false;
    }

    void otherKeyChanged()
    {
        if (_fnDown)
            _usedWithAnotherKey = true;
    }

    void cancel()
    {
        _fnDown = false;
        _usedWithAnotherKey = false;
        _tapReady = false;
    }

    bool takeTap()
    {
        const bool result = _tapReady;
        _tapReady = false;
        return result;
    }

private:
    bool _fnDown = false;
    bool _usedWithAnotherKey = false;
    bool _tapReady = false;
};

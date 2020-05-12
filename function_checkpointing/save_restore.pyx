from typing import Generator, List, Tuple
SavedStackFrame = Tuple[int, List, bytes]
import dis

from function_checkpointing.jump cimport *

class NULLObject(object):
    pass

def save_jump() -> List[SavedStackFrame]:
    saved_stack: List[SavedStackFrame] = []

    if PyThreadState_Get().interp.eval_frame == pyeval_fast_forward:
        set_evaluator()
        print('save_jump In the middle of a resume. Not saving.')
        return []

    cdef PyFrameObject *frame = PyEval_GetFrame()
    cdef child_frame_arg_count = 0  # initially, the argcount of save_jump()
    while frame.f_back:
        print('Saving frame "%s"' % <object>frame.f_code.co_name,
              'last_i=', frame.f_lasti,
              'co_argcount:', <object>frame.f_code.co_argcount)

        if frame.f_code.co_kwonlyargcount:
            raise NotImplementedError("Can't yet handle functions with kw arguments "
                    "in the call chain. Frame: " + str(<object>frame))

        # Take a guess at the stack size.

        # Add the local variables and the number of arguments we had to pass
        # to our child frame.
        stack_size = frame.f_valuestack - frame.f_localsplus + child_frame_arg_count

        # Disassemble the currently call instruction. Add the number of arguments
        # it needed to have on the stack.
        bytecode = dis.Bytecode(<object>frame.f_code, current_offset=frame.f_lasti)
        instructions = iter(bytecode)
        for _ in range(frame.f_lasti // 2):
            next(instructions)
        instr = next(instructions)

        # The arguments to the CALL_FUNCTION instruction or whatever instruction
        # caused the method call.
        if instr.opname == 'CALL_FUNCTION':
            # +1 for the address of the function being called
            stack_size += 1
        elif instr.opname == 'CALL_METHOD':
            # +1 for the address of the method, +1 for the object
            stack_size += 2
        elif instr.opname == 'CALL_FUNCTION_KW':
            # +1 for the address of the function, +1 for the tuple containing
            # the names of variables
            stack_size += 2
        elif instr.opname:
            raise NotImplementedError("Don't know how to checkpoint around opcode"
                    f" {instr.opname} "
                    "Here is the function:\n"
                    + bytecode.dis())

        # Save a copy of the stack using the above guess. Convent NULL pointers to
        # objects to a Python object sentinel value.
        stack_content = [
                <object>frame.f_localsplus[i] if frame.f_localsplus[i] else NULLObject
                for i in range(stack_size)
            ]

        saved_stack.append((
            <object> frame.f_lasti,
            stack_content,
            <object>frame.f_code
            ))

        child_frame_arg_count = frame.f_code.co_argcount
        frame = frame.f_back

    return saved_stack


cdef restore_frame(PyFrameObject *frame, saved_frame: SavedStackFrame):
    frame_obj = <object> frame
    saved_f_lasti, saved_stack_content, saved_f_code = saved_frame

    if frame_obj.f_code != saved_f_code:
        raise RuntimeError('Trying to restore frame from wrong snapshot:'
                f'\n   called_on.f_code: {frame_obj.f_code}'
                f'\n   saved_f_code: {saved_f_code}')

    print('Fast forwarding', frame_obj, 'to instruction', saved_f_lasti)

    # Fast forward the instruction pointer. f_lasti points to a CALL instruction
    # (a CALL_METHOD or CALL_FUNCTION or similar). The frame evaluator starts
    # executin at f_lasti+2, but in this case, we want it to re-execute the call
    # to force it to recurse on itself. So preemptively decrement f_lasti by 2.
    frame.f_lasti = saved_f_lasti - 2

    cdef int i = 0
    for o in saved_stack_content:
        # Restore the stack. Translate the sentinel value back to NULL.
        if o == NULLObject:
            frame.f_localsplus[i] = NULL
        else:
            frame.f_localsplus[i] = <PyObject*> o
            Py_INCREF(o)
        i += 1

    frame.f_stacktop = frame.f_localsplus + i

jump_stack = []


cdef PyObject* pyeval_fast_forward(PyFrameObject *frame, int exc):
    global jump_stack

    restore_frame(frame, jump_stack.pop())

    return _PyEval_EvalFrameDefault(frame, exc)


cdef _PyFrameEvalFunction *set_evaluator(_PyFrameEvalFunction *frame_evaluator = NULL):
    cdef PyThreadState *state = PyThreadState_Get()
    cdef _PyFrameEvalFunction *old_evaluator = state.interp.eval_frame

    if frame_evaluator:
        state.interp.eval_frame = frame_evaluator
    else:
        state.interp.eval_frame = _PyEval_EvalFrameDefault

    return old_evaluator 


def jump(saved_frames: List[SavedStackFrame]):
    global jump_stack_idx
    jump_stack.clear()
    jump_stack.extend(list(saved_frames))

    cdef PyFrameObject *f = PyEval_GetFrame()
    cdef PyFrameObject *top_frame = f
    while f.f_back:
        top_frame = f
        f = f.f_back

    set_evaluator(pyeval_fast_forward)
    return <object>pyeval_fast_forward(top_frame, 0)

using System;
using System.Collections;

namespace Sedulous.Editor.Core;

/// Interface for an undoable editor command.
public interface IEditorCommand
{
	/// Human-readable description of this command.
	void GetDescription(String outStr);
	/// Executes (or re-executes) the command.
	void Execute();
	/// Reverses the command.
	void Undo();
}

/// Command history with undo/redo stack.
///
/// All editor mutations go through this system so they can be undone.
/// When a new command is executed, the redo stack is cleared.
///
public class CommandHistory
{
	private List<IEditorCommand> mUndoStack = new .() ~ DeleteContainerAndItems!(_);
	private List<IEditorCommand> mRedoStack = new .() ~ DeleteContainerAndItems!(_);
	private int32 mMaxHistory = 100;

	/// Fired when the undo/redo state changes.
	public Event<delegate void()> OnHistoryChanged ~ _.Dispose();

	// ===== Properties =====

	/// Whether there are commands to undo.
	public bool CanUndo => mUndoStack.Count > 0;

	/// Whether there are commands to redo.
	public bool CanRedo => mRedoStack.Count > 0;

	/// Number of commands in undo history.
	public int UndoCount => mUndoStack.Count;

	/// Number of commands in redo history.
	public int RedoCount => mRedoStack.Count;

	/// Maximum number of undo steps.
	public int32 MaxHistory
	{
		get => mMaxHistory;
		set => mMaxHistory = Math.Max(value, 1);
	}

	// ===== Operations =====

	/// Executes a command and pushes it onto the undo stack.
	public void Execute(IEditorCommand command)
	{
		command.Execute();

		mUndoStack.Add(command);

		// Clear redo stack — branching history
		ClearAndDeleteItems(mRedoStack);

		// Trim if over max
		while (mUndoStack.Count > mMaxHistory)
		{
			delete mUndoStack[0];
			mUndoStack.RemoveAt(0);
		}

		OnHistoryChanged();
	}

	/// Undoes the last command.
	public void Undo()
	{
		if (mUndoStack.Count == 0)
			return;

		let cmd = mUndoStack.PopBack();
		cmd.Undo();
		mRedoStack.Add(cmd);

		OnHistoryChanged();
	}

	/// Redoes the last undone command.
	public void Redo()
	{
		if (mRedoStack.Count == 0)
			return;

		let cmd = mRedoStack.PopBack();
		cmd.Execute();
		mUndoStack.Add(cmd);

		OnHistoryChanged();
	}

	/// Clears all history.
	public void Clear()
	{
		ClearAndDeleteItems(mUndoStack);
		ClearAndDeleteItems(mRedoStack);
		OnHistoryChanged();
	}

	/// Gets description of the command that would be undone.
	public void GetUndoDescription(String outStr)
	{
		if (mUndoStack.Count > 0)
			mUndoStack.Back.GetDescription(outStr);
	}

	/// Gets description of the command that would be redone.
	public void GetRedoDescription(String outStr)
	{
		if (mRedoStack.Count > 0)
			mRedoStack.Back.GetDescription(outStr);
	}

	private static void ClearAndDeleteItems(List<IEditorCommand> list)
	{
		for (let item in list)
			delete item;
		list.Clear();
	}
}

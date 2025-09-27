using System;
using System.Threading.Tasks;

public interface ITransaction : IDisposable
{
    Task<IOperationResultWithUid> MutateAsync(string json);

    Task<IOperationResult> DeleteAsync(string json);

    Task<IOperationResult> CommitAsync();
    Task<IOperationResult> DiscardAsync();
}
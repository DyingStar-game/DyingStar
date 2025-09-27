using System;
using System.Collections.Generic;
using System.Linq;

public interface IOperationResult
{
    bool IsSuccess { get; }

    string ErrorMessage { get; }
    Exception Exception { get; }
}

public interface IOperationResultData: IOperationResult
{
    string Data { get; }
}

public interface IOperationResultWithUid : IOperationResultData
{
    string Uid { get; }
    Dictionary<string, string> Uids { get; }
}

public class OperationResult : IOperationResult
{
    public bool IsSuccess { get; set; }
    public string ErrorMessage { get; set; }
    public Exception Exception { get; set; }

    public static OperationResult Success() => new OperationResult { IsSuccess = true };
    public static OperationResult Failure(string error, Exception ex = null) =>
        new OperationResult { IsSuccess = false, ErrorMessage = error, Exception = ex };
}

public class OperationResultData : OperationResult, IOperationResult,IOperationResultData
{
    public string Data { get; set; }

    public static OperationResultData Success(string data) =>
        new OperationResultData { IsSuccess = true, Data = data };

    public static new OperationResultData Failure(string error, Exception ex = null) =>
        new OperationResultData { IsSuccess = false, ErrorMessage = error, Exception = ex };
}


public class OperationResultWithUid : OperationResult, IOperationResultWithUid, IOperationResultData
{
    public string Uid { get; set; }
    public string Data { get; set; }

    // Pour les mutations multiples, Dgraph peut retourner plusieurs UIDs
    public Dictionary<string, string> Uids { get; set; }

    public static OperationResultWithUid Success(string data, string uid) =>
        new OperationResultWithUid { IsSuccess = true, Data = data, Uid = uid };

    // Pour les mutations multiples avec plusieurs UIDs
    public static OperationResultWithUid Success(string data, Dictionary<string, string> uids) =>
        new OperationResultWithUid { IsSuccess = true, Data = data, Uids = uids, Uid = uids.First().Value };

    public static OperationResultWithUid Failure(string error, Exception ex = null) =>
        new OperationResultWithUid { IsSuccess = false, ErrorMessage = error, Exception = ex };

    public static OperationResultWithUid Failure(string error, string uid, Exception ex = null) =>
        new OperationResultWithUid { IsSuccess = false, ErrorMessage = error, Uid = uid, Exception = ex };
}
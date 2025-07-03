import numpy as np 
def average_cluster_distance(C1, C2): 
    """
    Compute the distance between the two clusters using Euclidean distance for points. 
    
    Args:
        C1: np.ndarray - points in the first cluster, shape (n1, n_features)
        C2: np.ndarray - points in the second cluster, shape (n2, n_features)
    
    Returns:
        float - the average linkage distance between the two clusters
    """
    dist = 0 
    for i in range(C1.shape[0]): 
        for j in range(C2.shape[0]): 
            dist += np.linalg.norm(C1[i] - C2[j])
    dist = dist / (C1.shape[0] * C2.shape[0])
    return dist